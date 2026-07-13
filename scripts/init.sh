#!/usr/bin/env bash
set -euo pipefail

# Redis / Sentinel init container script.
# Platform-neutral: only relies on standard Kubernetes env injection.
# Usage: init.sh server|sentinel

# Configurable paths and ports.
REDIS_TEMPLATE_PATH="${REDIS_TEMPLATE_PATH:-/etc/redis/redis-template.conf}"
REDIS_RUNTIME_CONFIG="${REDIS_RUNTIME_CONFIG:-/data/redis-runtime.conf}"
REDIS_ANNOUNCE_CONFIG="${REDIS_ANNOUNCE_CONFIG:-/data/redis-announce.conf}"
SENTINEL_CONFIG="${SENTINEL_CONFIG:-/data/sentinel.conf}"
REDIS_ACL_FILE="${REDIS_ACL_FILE:-/data/users.acl}"
REDIS_DATA_DIR="${REDIS_DATA_DIR:-/data/redis}"
LOG_DIR="${LOG_DIR:-/data/logs}"
REDIS_PORT="${REDIS_PORT:-6379}"
SENTINEL_PORT="${SENTINEL_PORT:-26379}"
KUBERNETES_CLUSTER_DOMAIN="${KUBERNETES_CLUSTER_DOMAIN:-cluster.local}"

# Globals set by resolve_announce_addr.
redis_announce_ip=""
redis_announce_port=""

derive_password() {
  local username="$1"
  printf '%s' "${REDIS_CLUSTER_ID}:${username}" | sha256sum | awk '{print $1}'
}

# Plaintext credential used for AUTH directives (masterauth, sentinel-pass,
# requirepass). The receiving ACL user stores the SHA-256 hash of this value.
derive_password_plaintext() {
  local username="$1"
  printf '%s' "${REDIS_CLUSTER_ID}:${username}"
}

ensure_dir() {
  local path="$1"
  if [[ ! -d "$path" ]]; then
    mkdir -p "$path"
  fi
}

# Ensure an ACL user line exists in the given file.
# If the user already exists, replace the line in place; otherwise append.
ensure_acl_user() {
  local file="$1"
  local username="$2"
  local rule="$3"

  if [[ ! -f "$file" ]]; then
    touch "$file"
  fi

  local temp_file
  temp_file=$(mktemp)

  awk -v user="$username" -v rule="$rule" '
    $1 == "user" && $2 == user { print rule; found = 1; next }
    { print }
    END { if (!found) print rule }
  ' "$file" > "$temp_file"

  mv "$temp_file" "$file"
}

# Ensure the default user is disabled if no default user line exists.
ensure_default_user() {
  local file="$1"
  if ! grep -qE "^user default " "$file"; then
    echo "user default off" >> "$file"
  fi
}

# Extract the trailing numeric ordinal from a name like "redis-server-0".
extract_obj_ordinal() {
  local object_name="$1"
  local ordinal="${object_name##*-}"
  echo "$ordinal"
}

# Split a comma-separated string into newline-delimited tokens.
split() {
  local value="$1"
  local delimiter="${2:-,}"
  printf '%s' "$value" | tr "$delimiter" '\n'
}

# Look up the entry matching the current Pod ordinal from a comma-separated
# list of "name:value" pairs. Prints the value on stdout and returns 0 if found.
lookup_value_by_ordinal() {
  local list="$1"
  local pod_name="${HOSTNAME:-}"
  local pod_ordinal
  pod_ordinal=$(extract_obj_ordinal "$pod_name")

  local entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    local svc_name="${entry%%:*}"
    local svc_value="${entry#*:}"
    local svc_ordinal
    svc_ordinal=$(extract_obj_ordinal "$svc_name")
    if [[ "$svc_ordinal" == "$pod_ordinal" ]]; then
      printf '%s' "$svc_value"
      return 0
    fi
  done <<< "$(split "$list" ",")"
  return 1
}

# Return the FQDN of the current Pod. Prefer hostname -f; fall back to
# constructing from HOSTNAME + KODA_HEADLESS_SERVICE + POD_NAMESPACE.
get_pod_fqdn() {
  local fqdn=""
  if command -v hostname >/dev/null 2>&1; then
    fqdn=$(hostname -f 2>/dev/null || true)
  fi
  if [[ -n "$fqdn" && "$fqdn" == *.* ]]; then
    printf '%s' "$fqdn"
    return 0
  fi

  local pod_name="${HOSTNAME:-}"
  local headless="${KODA_HEADLESS_SERVICE:-}"
  local ns="${POD_NAMESPACE:-default}"
  local domain="${KUBERNETES_CLUSTER_DOMAIN}"

  if [[ -n "$pod_name" && -n "$headless" ]]; then
    printf '%s' "${pod_name}.${headless}.${ns}.svc.${domain}"
    return 0
  fi

  return 1
}

# Resolve replica-announce-ip and replica-announce-port for the current Pod.
# Priority: HostNetwork > per-pod NodePort (future) > per-pod LB (future) > Headless.
resolve_announce_addr() {
  redis_announce_ip=""
  redis_announce_port=""

  # 1. HostNetwork mode.
  if [[ -n "${REDIS_HOST_NETWORK_PORT:-}" ]]; then
    redis_announce_ip="${CURRENT_POD_HOST_IP:-${CURRENT_POD_IP:-}}"
    redis_announce_port="${REDIS_HOST_NETWORK_PORT}"
    if [[ -n "$redis_announce_ip" && -n "$redis_announce_port" ]]; then
      return 0
    fi
  fi

  # 2. per-pod NodePort Service (future capability).
  if [[ -n "${REDIS_ADVERTISED_PORT:-}" ]]; then
    local advertised_port
    if advertised_port=$(lookup_value_by_ordinal "$REDIS_ADVERTISED_PORT"); then
      redis_announce_ip="${CURRENT_POD_HOST_IP:-${CURRENT_POD_IP:-}}"
      redis_announce_port="$advertised_port"
      if [[ -n "$redis_announce_ip" && -n "$redis_announce_port" ]]; then
        return 0
      fi
    fi
  fi

  # 3. per-pod LoadBalancer Service (future capability).
  if [[ -n "${REDIS_LB_ADVERTISED_HOST:-}" && -n "${REDIS_LB_ADVERTISED_PORT:-}" ]]; then
    local lb_host lb_port
    if lb_host=$(lookup_value_by_ordinal "$REDIS_LB_ADVERTISED_HOST") && \
       lb_port=$(lookup_value_by_ordinal "$REDIS_LB_ADVERTISED_PORT"); then
      redis_announce_ip="$lb_host"
      redis_announce_port="$lb_port"
      if [[ -n "$redis_announce_ip" && -n "$redis_announce_port" ]]; then
        return 0
      fi
    fi
  fi

  # 4. Headless Service fallback.
  redis_announce_ip=$(get_pod_fqdn)
  redis_announce_port="${REDIS_PORT}"
}

# Write the resolved announce values to the dedicated announce config file.
write_announce_conf() {
  cat > "$REDIS_ANNOUNCE_CONFIG" <<EOF
replica-announce-ip ${redis_announce_ip}
replica-announce-port ${redis_announce_port}
EOF
}

# Query Sentinel for the current master address. Prints "<ip> <port>" on stdout.
sentinel_master_addr() {
  local headless_svc="${KODA_SENTINEL_HEADLESS_SERVICE:-}"
  local replicas="${KODA_SENTINEL_REPLICAS:-}"
  if [[ -z "$headless_svc" || -z "$replicas" ]]; then
    return 1
  fi

  local prefix="${headless_svc%-headless}"
  local ns="${POD_NAMESPACE:-default}"
  local domain="${KUBERNETES_CLUSTER_DOMAIN}"
  local pass master_name output
  pass=$(derive_password op-sentinel)
  master_name="${REDIS_CLUSTER_ID}-master"

  local i
  for ((i = 0; i < replicas; i++)); do
    local fqdn="${prefix}-${i}.${headless_svc}.${ns}.svc.${domain}"
    output=$(redis-cli -h "$fqdn" -p "$SENTINEL_PORT" --user op-sentinel \
      --pass "$pass" --no-auth-warning SENTINEL MASTER "$master_name" 2>/dev/null || true)

    if [[ -n "$output" && "$output" != *"ERR"* ]]; then
      local master_ip master_port
      master_ip=$(printf '%s' "$output" | awk '/^ip$/{getline; print; exit}' | tr -d '\r')
      master_port=$(printf '%s' "$output" | awk '/^port$/{getline; print; exit}' | tr -d '\r')
      if [[ -n "$master_ip" && -n "$master_port" ]]; then
        printf '%s %s' "$master_ip" "$master_port"
        return 0
      fi
    fi
  done

  return 1
}

# Update or remove the replicaof line in the given config file.
# If the current Pod is the current master, remove replicaof; otherwise point it to the master.
update_replicaof() {
  local config_file="$1"
  local master_host="$2"
  local master_port="$3"
  local tmp_file
  tmp_file=$(mktemp)

  if [[ "$master_host" == "$redis_announce_ip" && "$master_port" == "$redis_announce_port" ]]; then
    # Current Pod is the master; ensure no replicaof remains.
    grep -vE '^replicaof[[:space:]]' "$config_file" > "$tmp_file" || true
  else
    # Replace existing replicaof or append a new one.
    grep -vE '^replicaof[[:space:]]' "$config_file" > "$tmp_file" || true
    echo "replicaof ${master_host} ${master_port}" >> "$tmp_file"
  fi

  mv "$tmp_file" "$config_file"
}

init_server() {
  ensure_dir "$REDIS_DATA_DIR"
  ensure_dir "$LOG_DIR"

  local first_creation=false
  if [[ ! -e "$REDIS_RUNTIME_CONFIG" ]]; then
    first_creation=true
    cat > "$REDIS_RUNTIME_CONFIG" <<EOF
include ${REDIS_TEMPLATE_PATH}
include ${REDIS_ANNOUNCE_CONFIG}
dir ${REDIS_DATA_DIR}
aclfile ${REDIS_ACL_FILE}
masteruser op-replica
masterauth $(derive_password_plaintext op-replica)
EOF
  fi

  # Always refresh announce configuration from the current Pod identity.
  resolve_announce_addr
  write_announce_conf

  # On Pod restart, when Sentinel is configured, ask Sentinel who the current master is
  # and update replicaof accordingly. Skip during first creation because Sentinel may not
  # be initialized yet.
  if [[ "$first_creation" == false ]]; then
    local sentinel_replicas="${KODA_SENTINEL_REPLICAS:-0}"
    if [[ "$sentinel_replicas" -gt 0 ]]; then
      local master_info
      if master_info=$(sentinel_master_addr); then
        local master_host master_port
        read -r master_host master_port <<< "$master_info"
        update_replicaof "$REDIS_RUNTIME_CONFIG" "$master_host" "$master_port"
      else
        echo "Warning: unable to query Sentinel for current master; leaving replicaof unchanged" >&2
      fi
    fi
  fi

  if [[ ! -e "$REDIS_ACL_FILE" ]]; then
    touch "$REDIS_ACL_FILE"
  fi

  ensure_acl_user "$REDIS_ACL_FILE" "op-replica" \
    "user op-replica on #$(derive_password op-replica) ~* &* +@all"
  ensure_default_user "$REDIS_ACL_FILE"
}

init_sentinel() {
  ensure_dir "$LOG_DIR"

  if [[ ! -e "$SENTINEL_CONFIG" ]]; then
    cat > "$SENTINEL_CONFIG" <<EOF
port ${SENTINEL_PORT}
aclfile ${REDIS_ACL_FILE}
sentinel sentinel-user op-sentinel
sentinel sentinel-pass $(derive_password_plaintext op-sentinel)
EOF
  fi

  if [[ ! -e "$REDIS_ACL_FILE" ]]; then
    touch "$REDIS_ACL_FILE"
  fi

  ensure_acl_user "$REDIS_ACL_FILE" "op-sentinel" \
    "user op-sentinel on #$(derive_password op-sentinel) ~* &* +@all"
  ensure_default_user "$REDIS_ACL_FILE"
}

main() {
  local component="${1:-}"

  REDIS_CLUSTER_ID="${REDIS_CLUSTER_ID:?REDIS_CLUSTER_ID is required}"

  case "$component" in
    server)
      init_server
      ;;
    sentinel)
      init_sentinel
      ;;
    *)
      echo "Error: unknown component '${component}'. Usage: $0 <server|sentinel>" >&2
      exit 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
