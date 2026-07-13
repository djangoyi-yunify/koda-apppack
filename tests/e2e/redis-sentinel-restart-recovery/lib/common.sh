#!/usr/bin/env bash
set -euo pipefail

# Expected Redis version for this test suite.
readonly REDIS_VERSION_EXPECTED="7.2.14"

# Default ports. Use non-standard ports to avoid colliding with other E2E suites.
readonly MASTER_PORT="${TEST_MASTER_PORT:-6390}"
readonly REPLICA_PORT="${TEST_REPLICA_PORT:-6391}"
readonly SENTINEL_PORT="${TEST_SENTINEL_PORT:-26390}"
export SENTINEL_PORT

# Cluster identity used by init.sh to derive passwords and master name.
readonly REDIS_CLUSTER_ID="${TEST_REDIS_CLUSTER_ID:-e2e-sentinel-restart}"
readonly MASTER_NAME="${REDIS_CLUSTER_ID}-master"

# Kubernetes-like Pod identity used by init.sh.
readonly KODA_HEADLESS_SERVICE="${TEST_KODA_HEADLESS_SERVICE:-demo-redis-headless}"
readonly KODA_SENTINEL_HEADLESS_SERVICE="${TEST_KODA_SENTINEL_HEADLESS_SERVICE:-demo-redis-sentinel-headless}"
readonly POD_NAMESPACE="${TEST_POD_NAMESPACE:-default}"
readonly KUBERNETES_CLUSTER_DOMAIN="${TEST_KUBERNETES_CLUSTER_DOMAIN:-cluster.local}"
export REDIS_CLUSTER_ID KODA_HEADLESS_SERVICE KODA_SENTINEL_HEADLESS_SERVICE POD_NAMESPACE KUBERNETES_CLUSTER_DOMAIN

# Static Redis application password. init.sh does not write requirepass, so the
# read-only template provides it. Sentinel auth-pass uses the same password.
readonly REDIS_PASSWORD="${TEST_REDIS_PASSWORD:-e2e-redis-pass}"

# Project paths.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
INIT_SCRIPT="${PROJECT_ROOT}/scripts/init.sh"

# Working directory created by create_work_dir.
WORK_DIR=""

# Array of process IDs started by this test run.
PIDS=()

# check_redis_version verifies the local redis-server matches the expected version.
check_redis_version() {
    local version
    version=$(redis-server --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [[ -z "$version" ]]; then
        echo "ERROR: Unable to determine redis-server version. Is Redis installed?"
        exit 1
    fi
    if [[ "$version" != "$REDIS_VERSION_EXPECTED" ]]; then
        echo "ERROR: Expected Redis ${REDIS_VERSION_EXPECTED}, found ${version}"
        exit 1
    fi
    echo "OK: Redis ${version}"
}

# check_port fails if the given TCP port is already in use on 127.0.0.1.
check_port() {
    local port=$1
    if command -v nc >/dev/null 2>&1; then
        if nc -z 127.0.0.1 "$port" 2>/dev/null; then
            echo "ERROR: Port ${port} is already in use"
            exit 1
        fi
    elif command -v ss >/dev/null 2>&1; then
        if ss -tln 2>/dev/null | grep -qE ":${port}[[:space:]]"; then
            echo "ERROR: Port ${port} is already in use"
            exit 1
        fi
    fi
}

# check_all_ports ensures the default test ports are available.
check_all_ports() {
    check_port "$MASTER_PORT"
    check_port "$REPLICA_PORT"
    check_port "$SENTINEL_PORT"
}

# derive_password mirrors the derivation in scripts/init.sh.
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

# create_work_dir creates a fresh /tmp directory with isolated instance dirs.
create_work_dir() {
    WORK_DIR=$(mktemp -d /tmp/redis-sentinel-restart-e2e-XXXXXX)
    mkdir -p "$WORK_DIR/master/data"
    mkdir -p "$WORK_DIR/replica/data"
    mkdir -p "$WORK_DIR/sentinel/data"
    echo "$WORK_DIR"
}

# create_redis_template writes a per-instance static template.
create_redis_template() {
    local dir=$1
    cat > "$dir/redis-template.conf" <<EOF
bind 127.0.0.1
port 0
protected-mode no
dir $dir/data
maxmemory 256mb
appendonly yes
requirepass $REDIS_PASSWORD
EOF
}

# redis_cli invokes redis-cli authenticated as the op-replica ACL user. The
# default user is disabled by init.sh, so client connections must use the
# replica operator user created by init.sh server.
redis_cli() {
    REDISCLI_AUTH="$(derive_password_plaintext op-replica)" redis-cli --user op-replica "$@"
}

# sentinel_cli invokes redis-cli authenticated as the op-sentinel ACL user.
sentinel_cli() {
    REDISCLI_AUTH="$(derive_password_plaintext op-sentinel)" redis-cli -p "$SENTINEL_PORT" --user op-sentinel "$@"
}

# wait_for_redis waits until the Redis instance on the given port responds to PING.
wait_for_redis() {
    local port=$1
    local timeout=${2:-30}
    local i=0
    while ! redis_cli -p "$port" PING >/dev/null 2>&1; do
        if (( i >= timeout )); then
            echo "ERROR: Redis on port ${port} did not start within ${timeout}s"
            exit 1
        fi
        sleep 1
        ((i++))
    done
}

# wait_for_replica_sync waits until the replica is connected and synced.
wait_for_replica_sync() {
    local port=$1
    local timeout=${2:-60}
    local i=0
    while true; do
        local info
        info=$(redis_cli -p "$port" INFO replication 2>/dev/null || true)
        if echo "$info" | grep -q "role:slave" && echo "$info" | grep -q "master_link_status:up"; then
            break
        fi
        if (( i >= timeout )); then
            echo "ERROR: Replica on port ${port} did not sync within ${timeout}s"
            echo "$info"
            exit 1
        fi
        sleep 1
        i=$((i+1))
    done
}

# wait_for_sentinel waits until the Sentinel instance responds.
wait_for_sentinel() {
    local timeout=${1:-30}
    local i=0
    while ! sentinel_cli SENTINEL master "$MASTER_NAME" >/dev/null 2>&1; do
        if (( i >= timeout )); then
            echo "ERROR: Sentinel did not start within ${timeout}s"
            exit 1
        fi
        sleep 1
        i=$((i+1))
    done
}

# wait_for_sentinel_failover_complete waits until Sentinel finishes the current failover.
wait_for_sentinel_failover_complete() {
    local timeout=${1:-60}
    local i=0

    # Wait for failover to start.
    while true; do
        local state
        state=$(sentinel_cli SENTINEL master "$MASTER_NAME" 2>/dev/null | awk '/^failover-state$/{getline; print}' | tr -d '\r' || true)
        if [[ -n "$state" ]]; then
            break
        fi
        if (( i >= timeout )); then
            echo "ERROR: Sentinel failover did not start within ${timeout}s"
            exit 1
        fi
        sleep 0.5
        i=$((i+1))
    done

    # Wait for failover to finish.
    while true; do
        local state
        state=$(sentinel_cli SENTINEL master "$MASTER_NAME" 2>/dev/null | awk '/^failover-state$/{getline; print}' | tr -d '\r' || true)
        if [[ -z "$state" ]]; then
            break
        fi
        if (( i >= timeout )); then
            echo "ERROR: Sentinel failover did not complete within ${timeout}s (state=${state})"
            exit 1
        fi
        sleep 0.5
        i=$((i+1))
    done
}

# wait_for_sentinel_slaves waits until Sentinel discovers the expected number of healthy replicas.
wait_for_sentinel_slaves() {
    local expected=$1
    local timeout=${2:-60}
    local i=0
    while true; do
        local slaves_info
        slaves_info=$(sentinel_cli SENTINEL slaves "$MASTER_NAME" 2>/dev/null || true)
        local count
        count=$(echo "$slaves_info" | grep -c "^name$" || true)
        local ok_count
        ok_count=$(echo "$slaves_info" | grep -c "master-link-status" || true)
        if [[ "$count" -ge "$expected" && "$ok_count" -ge "$expected" ]]; then
            break
        fi
        if (( i >= timeout )); then
            echo "ERROR: Sentinel did not discover ${expected} healthy slave(s) within ${timeout}s (found ${count}, ok ${ok_count})"
            echo "$slaves_info"
            exit 1
        fi
        sleep 1
        i=$((i+1))
    done
}

# wait_for_failover waits until Sentinel reports the given Redis instance as the new master
# and the instance itself reports role:master.
wait_for_failover() {
    local port=$1
    local timeout=${2:-60}
    local i=0
    while true; do
        local info
        info=$(redis_cli -p "$port" INFO replication 2>/dev/null || true)
        local sentinel_master_port
        sentinel_master_port=$(sentinel_cli SENTINEL get-master-addr-by-name "$MASTER_NAME" 2>/dev/null | tail -1 | tr -d '\r' || true)
        if echo "$info" | grep -q "role:master" && [[ "$sentinel_master_port" == "$port" ]]; then
            break
        fi
        if (( i >= timeout )); then
            echo "ERROR: Failover did not complete on port ${port} within ${timeout}s"
            echo "instance role info:"
            echo "$info"
            echo "sentinel reported master port: ${sentinel_master_port}"
            exit 1
        fi
        sleep 1
        i=$((i+1))
    done
}

# start_redis_server starts a redis-server for the given instance directory.
# Uses daemonize mode and a pidfile so the actual process ID can be captured reliably.
start_redis_server() {
    local dir=$1
    local pidfile="$dir/redis-server.pid"
    rm -f "$pidfile"
    (cd "$dir" && redis-server "./redis-runtime.conf" --daemonize yes --pidfile "$pidfile") >/dev/null 2>&1
    local pid
    local i=0
    while [[ ! -f "$pidfile" ]]; do
        if (( i >= 50 )); then
            echo "ERROR: redis-server did not write pidfile"
            exit 1
        fi
        sleep 0.1
        i=$((i+1))
    done
    pid=$(cat "$pidfile")
    PIDS+=("$pid")
    echo "$pid"
}

# start_sentinel starts a redis-sentinel for the given instance directory.
start_sentinel() {
    local dir=$1
    local pidfile="$dir/redis-sentinel.pid"
    rm -f "$pidfile"
    (cd "$dir" && redis-sentinel "./sentinel.conf" --daemonize yes --pidfile "$pidfile") >/dev/null 2>&1
    local pid
    local i=0
    while [[ ! -f "$pidfile" ]]; do
        if (( i >= 50 )); then
            echo "ERROR: redis-sentinel did not write pidfile"
            exit 1
        fi
        sleep 0.1
        i=$((i+1))
    done
    pid=$(cat "$pidfile")
    PIDS+=("$pid")
    echo "$pid"
}

# create_sentinel_config writes the Sentinel configuration file and ensures the
# ACL user used by init.sh exists. The sentinel sentinel-pass and requirepass
# are the plaintext credential derived from REDIS_CLUSTER_ID; the ACL user
# stores its SHA-256 hash. requirepass lets redis-cli authenticate as the
# default user.
create_sentinel_config() {
    local dir=$1
    local acl_file="$dir/users.acl"
    local sentinel_pass
    sentinel_pass=$(derive_password_plaintext op-sentinel)
    local replica_pass
    replica_pass=$(derive_password_plaintext op-replica)

    cat > "$dir/sentinel.conf" <<EOF
bind 127.0.0.1
port $SENTINEL_PORT
requirepass $sentinel_pass
aclfile $acl_file
sentinel sentinel-user op-sentinel
sentinel sentinel-pass $sentinel_pass
sentinel monitor $MASTER_NAME 127.0.0.1 $MASTER_PORT 1
sentinel down-after-milliseconds $MASTER_NAME 3000
sentinel failover-timeout $MASTER_NAME 5000
sentinel auth-user $MASTER_NAME op-replica
sentinel auth-pass $MASTER_NAME $replica_pass
EOF

    # Run init.sh sentinel to create the ACL file with the op-sentinel user.
    # init.sh preserves an existing sentinel.conf, so our monitor config is kept.
    SENTINEL_CONFIG="$dir/sentinel.conf" \
    REDIS_ACL_FILE="$acl_file" \
    LOG_DIR="$dir/logs" \
    bash "$INIT_SCRIPT" sentinel
}

# init_server_env exports environment variables expected by init.sh server for
# the given instance directory and Pod hostname.
init_server_env() {
    local dir=$1
    local hostname="$2"
    local host_network_port="${3:-6379}"

    # REDIS_CLUSTER_ID, KODA_HEADLESS_SERVICE and related identity vars are
    # already exported as readonly by common.sh; only re-export the per-instance
    # and per-directory variables here.
    export HOSTNAME="$hostname"
    export KODA_SENTINEL_REPLICAS="1"

    # Use HostNetwork mode for announce values so the local E2E environment can
    # resolve and connect to instances on 127.0.0.1 without a Kubernetes DNS.
    export CURRENT_POD_HOST_IP="127.0.0.1"
    export REDIS_HOST_NETWORK_PORT="$host_network_port"

    export REDIS_TEMPLATE_PATH="$dir/redis-template.conf"
    export REDIS_RUNTIME_CONFIG="$dir/redis-runtime.conf"
    export REDIS_ANNOUNCE_CONFIG="$dir/redis-announce.conf"
    export REDIS_ACL_FILE="$dir/users.acl"
    export REDIS_DATA_DIR="$dir/data"
    export LOG_DIR="$dir/logs"
    export REDIS_PORT="6379"
}

# run_init_server_first_creation runs init.sh server for a fresh instance.
run_init_server_first_creation() {
    local dir=$1
    local hostname="$2"
    local port="${3:-6379}"

    init_server_env "$dir" "$hostname" "$port"
    bash "$INIT_SCRIPT" server
}

# run_init_server_restart simulates a Pod restart by running init.sh server with
# mocked hostname and redis-cli commands in PATH.
run_init_server_restart() {
    local dir=$1
    local hostname="$2"
    local port="${3:-6379}"
    local mock_dir
    mock_dir=$(mktemp -d)

    init_server_env "$dir" "$hostname" "$port"

    # Mock hostname -f to return the deterministic Pod FQDN.
    cat > "$mock_dir/hostname" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == "-f" ]]; then
  printf '%s\n' "\${HOSTNAME}.\${KODA_HEADLESS_SERVICE}.\${POD_NAMESPACE}.svc.\${KUBERNETES_CLUSTER_DOMAIN}"
else
  printf '%s\n' "\${HOSTNAME}"
fi
EOF
    chmod +x "$mock_dir/hostname"

    # Capture the real redis-cli so the mock can delegate non-Sentinel commands.
    local real_redis_cli
    real_redis_cli=$(command -v redis-cli)

    # Mock redis-cli to redirect init.sh's Sentinel queries to the local Sentinel.
    # All other commands are delegated to the real redis-cli unchanged.
    cat > "$mock_dir/redis-cli" <<EOF
#!/usr/bin/env bash
# Redirect SENTINEL MASTER queries to the local Sentinel instance; the real
# Sentinel FQDN is not resolvable in this self-contained E2E environment.
if [[ "\$*" == *"SENTINEL MASTER"* ]]; then
  "$real_redis_cli" -h 127.0.0.1 -p "$SENTINEL_PORT" --user op-sentinel -a "$(derive_password_plaintext op-sentinel)" --no-auth-warning SENTINEL MASTER "$MASTER_NAME"
else
  "$real_redis_cli" "\$@"
fi
EOF
    chmod +x "$mock_dir/redis-cli"

    PATH="${mock_dir}:${PATH}" bash "$INIT_SCRIPT" server

    rm -rf "$mock_dir"
}

# stop_process terminates a background process.
stop_process() {
    local pid=$1
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
}

# cleanup stops all started processes and removes the working directory unless
# E2E_NO_CLEANUP is set to 1.
cleanup() {
    if [[ "${E2E_NO_CLEANUP:-}" == "1" ]]; then
        return
    fi
    for pid in "${PIDS[@]}"; do
        stop_process "$pid"
    done
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}

trap cleanup EXIT
