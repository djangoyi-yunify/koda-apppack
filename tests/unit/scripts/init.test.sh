#!/usr/bin/env bash
set -euo pipefail

# Unit tests for scripts/init.sh.
# Each test runs in a subshell so failures do not abort the suite.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
INIT_SCRIPT="${PROJECT_ROOT}/scripts/init.sh"

# Run a named test function in a subshell so failures do not abort the suite.
run_test() {
  local name=$1
  echo ""
  echo "Running: ${name}"
  if ("${name}"); then
    echo "PASS: ${name}"
  else
    echo "FAIL: ${name}"
    exit 1
  fi
}

# Create a fake hostname command in a temp dir so get_pod_fqdn returns a deterministic value.
make_fake_hostname() {
  local dir=$1
  cat > "${dir}/hostname" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-f" ]]; then
  printf '%s\n' "${HOSTNAME}.${KODA_HEADLESS_SERVICE}.${POD_NAMESPACE}.svc.${KUBERNETES_CLUSTER_DOMAIN}"
else
  printf '%s\n' "${HOSTNAME}"
fi
EOF
  chmod +x "${dir}/hostname"
}

# Create a fake redis-cli in a temp dir that emulates Sentinel responses.
make_fake_redis_cli() {
  local dir=$1
  local response="${2:-}"
  cat > "${dir}/redis-cli" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\${FAKE_REDIS_CLI_LOG}"
if [[ "\$*" == *"SENTINEL MASTER"* ]]; then
  cat <<RESP
${response}
RESP
else
  echo "OK"
fi
EOF
  chmod +x "${dir}/redis-cli"
}

# Common environment for init.sh tests.
setup_env() {
  local tmpdir="$1"

  export REDIS_CLUSTER_ID="test-cluster"
  export REDIS_PORT="6379"
  export SENTINEL_PORT="26379"
  export HOSTNAME="redis-server-0"
  export KODA_HEADLESS_SERVICE="demo-redis-headless"
  export POD_NAMESPACE="default"
  export KUBERNETES_CLUSTER_DOMAIN="cluster.local"

  export REDIS_TEMPLATE_PATH="${tmpdir}/redis-template.conf"
  export REDIS_RUNTIME_CONFIG="${tmpdir}/redis-runtime.conf"
  export REDIS_ANNOUNCE_CONFIG="${tmpdir}/redis-announce.conf"
  export REDIS_ACL_FILE="${tmpdir}/users.acl"
  export REDIS_DATA_DIR="${tmpdir}/redis"
  export LOG_DIR="${tmpdir}/logs"

  echo "bind 127.0.0.1" > "$REDIS_TEMPLATE_PATH"

  make_fake_hostname "$tmpdir"
  export PATH="${tmpdir}:${PATH}"
}

# Test: headless fallback derives Pod FQDN and container port.
test_resolve_announce_addr_headless() {
  local tmpdir
  tmpdir=$(mktemp -d)
  setup_env "$tmpdir"

  # shellcheck source=../../../scripts/init.sh
  source "$INIT_SCRIPT"

  unset REDIS_HOST_NETWORK_PORT REDIS_ADVERTISED_PORT REDIS_LB_ADVERTISED_HOST REDIS_LB_ADVERTISED_PORT
  resolve_announce_addr

  local expected_fqdn
  expected_fqdn="${HOSTNAME}.${KODA_HEADLESS_SERVICE}.${POD_NAMESPACE}.svc.${KUBERNETES_CLUSTER_DOMAIN}"
  [[ "$redis_announce_ip" == "$expected_fqdn" ]] || {
    echo "expected announce-ip=${expected_fqdn}, got ${redis_announce_ip}"; return 1;
  }
  [[ "$redis_announce_port" == "6379" ]] || {
    echo "expected announce-port=6379, got ${redis_announce_port}"; return 1;
  }

  rm -rf "$tmpdir"
}

# Test: HostNetwork mode uses the allocated host port and node IP.
test_resolve_announce_addr_hostnetwork() {
  local tmpdir
  tmpdir=$(mktemp -d)
  setup_env "$tmpdir"

  source "$INIT_SCRIPT"

  unset REDIS_ADVERTISED_PORT REDIS_LB_ADVERTISED_HOST REDIS_LB_ADVERTISED_PORT
  export REDIS_HOST_NETWORK_PORT="30001"
  export CURRENT_POD_HOST_IP="192.168.1.10"

  resolve_announce_addr

  [[ "$redis_announce_ip" == "192.168.1.10" ]] || {
    echo "expected announce-ip=192.168.1.10, got ${redis_announce_ip}"; return 1;
  }
  [[ "$redis_announce_port" == "30001" ]] || {
    echo "expected announce-port=30001, got ${redis_announce_port}"; return 1;
  }

  rm -rf "$tmpdir"
}

# Test: per-pod NodePort parsing matches the current Pod ordinal.
test_resolve_announce_addr_nodeport() {
  local tmpdir
  tmpdir=$(mktemp -d)
  setup_env "$tmpdir"
  export HOSTNAME="redis-server-1"
  source "$INIT_SCRIPT"

  unset REDIS_HOST_NETWORK_PORT REDIS_LB_ADVERTISED_HOST REDIS_LB_ADVERTISED_PORT
  export REDIS_ADVERTISED_PORT="demo-redis-advertised-0:30001,demo-redis-advertised-1:30002,demo-redis-advertised-2:30003"
  export CURRENT_POD_HOST_IP="192.168.1.11"

  resolve_announce_addr

  [[ "$redis_announce_ip" == "192.168.1.11" ]] || {
    echo "expected announce-ip=192.168.1.11, got ${redis_announce_ip}"; return 1;
  }
  [[ "$redis_announce_port" == "30002" ]] || {
    echo "expected announce-port=30002, got ${redis_announce_port}"; return 1;
  }

  rm -rf "$tmpdir"
}

# Test: per-pod LoadBalancer parsing matches the current Pod ordinal.
test_resolve_announce_addr_lb() {
  local tmpdir
  tmpdir=$(mktemp -d)
  setup_env "$tmpdir"
  export HOSTNAME="redis-server-2"
  source "$INIT_SCRIPT"

  unset REDIS_HOST_NETWORK_PORT REDIS_ADVERTISED_PORT
  export REDIS_LB_ADVERTISED_HOST="demo-redis-lb-0:lb-0.example.com,demo-redis-lb-1:lb-1.example.com,demo-redis-lb-2:lb-2.example.com"
  export REDIS_LB_ADVERTISED_PORT="demo-redis-lb-0:6379,demo-redis-lb-1:6379,demo-redis-lb-2:6379"

  resolve_announce_addr

  [[ "$redis_announce_ip" == "lb-2.example.com" ]] || {
    echo "expected announce-ip=lb-2.example.com, got ${redis_announce_ip}"; return 1;
  }
  [[ "$redis_announce_port" == "6379" ]] || {
    echo "expected announce-port=6379, got ${redis_announce_port}"; return 1;
  }

  rm -rf "$tmpdir"
}

# Test: first creation generates runtime config with announce include and no replicaof.
test_init_server_first_creation() {
  local tmpdir
  tmpdir=$(mktemp -d)
  setup_env "$tmpdir"
  source "$INIT_SCRIPT"

  init_server

  [[ -f "$REDIS_RUNTIME_CONFIG" ]] || { echo "runtime config missing"; return 1; }
  grep -qF "include ${REDIS_ANNOUNCE_CONFIG}" "$REDIS_RUNTIME_CONFIG" || { echo "missing include redis-announce.conf"; return 1; }
  grep -qE '^replicaof[[:space:]]' "$REDIS_RUNTIME_CONFIG" && { echo "unexpected replicaof on first creation"; return 1; }

  [[ -f "$REDIS_ANNOUNCE_CONFIG" ]] || { echo "announce config missing"; return 1; }
  local expected_fqdn
  expected_fqdn="${HOSTNAME}.${KODA_HEADLESS_SERVICE}.${POD_NAMESPACE}.svc.${KUBERNETES_CLUSTER_DOMAIN}"
  grep -qF "replica-announce-ip ${expected_fqdn}" "$REDIS_ANNOUNCE_CONFIG" || { echo "unexpected announce-ip"; cat "$REDIS_ANNOUNCE_CONFIG"; return 1; }
  grep -qF "replica-announce-port 6379" "$REDIS_ANNOUNCE_CONFIG" || { echo "unexpected announce-port"; cat "$REDIS_ANNOUNCE_CONFIG"; return 1; }

  rm -rf "$tmpdir"
}

# Test: Pod restart updates announce config and replicaof from Sentinel.
test_init_server_restart_updates_replicaof() {
  local tmpdir
  tmpdir=$(mktemp -d)
  setup_env "$tmpdir"

  export KODA_SENTINEL_HEADLESS_SERVICE="demo-redis-sentinel-headless"
  export KODA_SENTINEL_REPLICAS="3"

  local log="${tmpdir}/redis-cli.log"
  local sentinel_response
  sentinel_response=$'name\ntest-cluster-master\nip\nredis-server-1.demo-redis-headless.default.svc.cluster.local\nport\n6379\nflags\nmaster'
  make_fake_redis_cli "$tmpdir" "$sentinel_response"
  export FAKE_REDIS_CLI_LOG="$log"
  export PATH="${tmpdir}:${PATH}"

  source "$INIT_SCRIPT"

  # Simulate an existing runtime config from a previous master.
  cat > "$REDIS_RUNTIME_CONFIG" <<EOF
include ${REDIS_TEMPLATE_PATH}
include ${REDIS_ANNOUNCE_CONFIG}
dir ${REDIS_DATA_DIR}
replicaof redis-server-0.demo-redis-headless.default.svc.cluster.local 6379
masterauth oldhash
EOF

  init_server

  grep -qF "replicaof redis-server-1.demo-redis-headless.default.svc.cluster.local 6379" "$REDIS_RUNTIME_CONFIG" || {
    echo "replicaof not updated"; cat "$REDIS_RUNTIME_CONFIG"; return 1;
  }
  grep -qF "masterauth oldhash" "$REDIS_RUNTIME_CONFIG" || {
    echo "existing content was overwritten"; cat "$REDIS_RUNTIME_CONFIG"; return 1;
  }

  rm -rf "$tmpdir"
}

# Test: Pod restart removes replicaof when the current Pod is the current master.
test_init_server_restart_current_pod_is_master() {
  local tmpdir
  tmpdir=$(mktemp -d)
  setup_env "$tmpdir"

  export KODA_SENTINEL_HEADLESS_SERVICE="demo-redis-sentinel-headless"
  export KODA_SENTINEL_REPLICAS="3"

  local expected_fqdn
  expected_fqdn="${HOSTNAME}.${KODA_HEADLESS_SERVICE}.${POD_NAMESPACE}.svc.${KUBERNETES_CLUSTER_DOMAIN}"
  local sentinel_response
  sentinel_response=$'name\ntest-cluster-master\nip\n'"${expected_fqdn}"$'\nport\n6379\nflags\nmaster'
  make_fake_redis_cli "$tmpdir" "$sentinel_response"
  export PATH="${tmpdir}:${PATH}"

  source "$INIT_SCRIPT"

  cat > "$REDIS_RUNTIME_CONFIG" <<EOF
include ${REDIS_TEMPLATE_PATH}
include ${REDIS_ANNOUNCE_CONFIG}
replicaof redis-server-1.demo-redis-headless.default.svc.cluster.local 6379
EOF

  init_server

  grep -qE '^replicaof[[:space:]]' "$REDIS_RUNTIME_CONFIG" && {
    echo "replicaof should have been removed"; cat "$REDIS_RUNTIME_CONFIG"; return 1;
  }

  rm -rf "$tmpdir"
}

# Test: Sentinel query failure logs a warning but does not fail.
test_init_server_restart_sentinel_query_fails() {
  local tmpdir
  tmpdir=$(mktemp -d)
  setup_env "$tmpdir"

  export KODA_SENTINEL_HEADLESS_SERVICE="demo-redis-sentinel-headless"
  export KODA_SENTINEL_REPLICAS="3"

  make_fake_redis_cli "$tmpdir" "ERR No such master"
  export PATH="${tmpdir}:${PATH}"

  source "$INIT_SCRIPT"

  cat > "$REDIS_RUNTIME_CONFIG" <<EOF
include ${REDIS_TEMPLATE_PATH}
include ${REDIS_ANNOUNCE_CONFIG}
replicaof redis-server-0.demo-redis-headless.default.svc.cluster.local 6379
EOF

  init_server

  grep -qF "replicaof redis-server-0.demo-redis-headless.default.svc.cluster.local 6379" "$REDIS_RUNTIME_CONFIG" || {
    echo "replicaof should remain unchanged after Sentinel query failure"; cat "$REDIS_RUNTIME_CONFIG"; return 1;
  }

  rm -rf "$tmpdir"
}

# Test: first creation skips Sentinel query even when Sentinel envs are set.
test_init_server_first_creation_skips_sentinel() {
  local tmpdir
  tmpdir=$(mktemp -d)
  setup_env "$tmpdir"

  export KODA_SENTINEL_HEADLESS_SERVICE="demo-redis-sentinel-headless"
  export KODA_SENTINEL_REPLICAS="3"

  local log="${tmpdir}/redis-cli.log"
  make_fake_redis_cli "$tmpdir" ""
  export FAKE_REDIS_CLI_LOG="$log"
  export PATH="${tmpdir}:${PATH}"

  source "$INIT_SCRIPT"

  init_server

  [[ ! -s "$log" ]] || { echo "redis-cli should not have been invoked on first creation"; cat "$log"; return 1; }

  rm -rf "$tmpdir"
}

echo "=== init.sh unit tests ==="
run_test test_resolve_announce_addr_headless
run_test test_resolve_announce_addr_hostnetwork
run_test test_resolve_announce_addr_nodeport
run_test test_resolve_announce_addr_lb
run_test test_init_server_first_creation
run_test test_init_server_restart_updates_replicaof
run_test test_init_server_restart_current_pod_is_master
run_test test_init_server_restart_sentinel_query_fails
run_test test_init_server_first_creation_skips_sentinel

echo ""
echo "=== All init.sh unit tests passed ==="
