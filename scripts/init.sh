#!/usr/bin/env bash
set -euo pipefail

# Redis / Sentinel init container script.
# Platform-neutral: only relies on standard Kubernetes env injection.
# Usage: init.sh server|sentinel

COMPONENT="${1:-}"

# Required environment variable.
REDIS_CLUSTER_ID="${REDIS_CLUSTER_ID:?REDIS_CLUSTER_ID is required}"

# Configurable paths and ports.
REDIS_TEMPLATE_PATH="${REDIS_TEMPLATE_PATH:-/etc/redis/redis-template.conf}"
REDIS_RUNTIME_CONFIG="${REDIS_RUNTIME_CONFIG:-/data/redis-runtime.conf}"
SENTINEL_CONFIG="${SENTINEL_CONFIG:-/data/sentinel.conf}"
REDIS_ACL_FILE="${REDIS_ACL_FILE:-/data/users.acl}"
REDIS_DATA_DIR="${REDIS_DATA_DIR:-/data/redis}"
LOG_DIR="${LOG_DIR:-/data/logs}"
REDIS_PORT="${REDIS_PORT:-6379}"
SENTINEL_PORT="${SENTINEL_PORT:-26379}"

derive_password() {
  local username="$1"
  printf '%s' "${REDIS_CLUSTER_ID}:${username}" | sha256sum | awk '{print $1}'
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

init_server() {
  ensure_dir "$REDIS_DATA_DIR"
  ensure_dir "$LOG_DIR"

  if [[ ! -e "$REDIS_RUNTIME_CONFIG" ]]; then
    cat > "$REDIS_RUNTIME_CONFIG" <<EOF
include ${REDIS_TEMPLATE_PATH}
dir ${REDIS_DATA_DIR}
aclfile ${REDIS_ACL_FILE}
masteruser op-replica
masterauth $(derive_password op-replica)
EOF
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
sentinel sentinel-pass $(derive_password op-sentinel)
EOF
  fi

  if [[ ! -e "$REDIS_ACL_FILE" ]]; then
    touch "$REDIS_ACL_FILE"
  fi

  ensure_acl_user "$REDIS_ACL_FILE" "op-sentinel" \
    "user op-sentinel on #$(derive_password op-sentinel) ~* &* +@all"
  ensure_default_user "$REDIS_ACL_FILE"
}

case "$COMPONENT" in
  server)
    init_server
    ;;
  sentinel)
    init_sentinel
    ;;
  *)
    echo "Error: unknown component '${COMPONENT}'. Usage: $0 <server|sentinel>" >&2
    exit 1
    ;;
esac
