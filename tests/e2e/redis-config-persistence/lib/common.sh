#!/usr/bin/env bash
set -euo pipefail

# Expected Redis version for this test suite.
readonly REDIS_VERSION_EXPECTED="7.2.14"

# Default ports. Can be overridden via environment variables.
readonly MASTER_PORT="${TEST_MASTER_PORT:-6379}"
readonly REPLICA_PORT="${TEST_REPLICA_PORT:-6380}"
readonly SENTINEL_PORT="${TEST_SENTINEL_PORT:-26379}"

# Authentication passwords.
readonly REDIS_PASSWORD="${TEST_REDIS_PASSWORD:-defaultpass}"
readonly SENTINEL_PASSWORD="${TEST_SENTINEL_PASSWORD:-sentinelpass}"
readonly MASTER_NAME="${TEST_MASTER_NAME:-mymaster}"

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

# create_work_dir creates a fresh /tmp directory with isolated instance dirs.
create_work_dir() {
    WORK_DIR=$(mktemp -d /tmp/redis-cfg-e2e-XXXXXX)
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

# create_redis_runtime writes the writable main config for a Redis instance.
create_redis_runtime() {
    local dir=$1
    local port=$2
    cat > "$dir/redis-runtime.conf" <<EOF
include ./redis-template.conf
port $port
EOF
}

# create_sentinel_config writes the Sentinel configuration file.
create_sentinel_config() {
    local dir=$1
    cat > "$dir/sentinel.conf" <<EOF
bind 127.0.0.1
port $SENTINEL_PORT
requirepass $SENTINEL_PASSWORD
sentinel monitor $MASTER_NAME 127.0.0.1 $MASTER_PORT 1
sentinel down-after-milliseconds $MASTER_NAME 3000
sentinel failover-timeout $MASTER_NAME 5000
sentinel auth-pass $MASTER_NAME $REDIS_PASSWORD
EOF
}

# start_redis_server starts a redis-server for the given instance directory.
# Uses daemonize mode and a pidfile so the actual process ID can be captured reliably.
start_redis_server() {
    local dir=$1
    local config=${2:-redis-runtime.conf}
    local pidfile="$dir/redis-server.pid"
    rm -f "$pidfile"
    (cd "$dir" && redis-server "./$config" --daemonize yes --pidfile "$pidfile") >/dev/null 2>&1
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

# redis_cli invokes redis-cli authenticated for Redis instances.
redis_cli() {
    REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli "$@"
}

# sentinel_cli invokes redis-cli authenticated for the Sentinel instance.
sentinel_cli() {
    REDISCLI_AUTH="$SENTINEL_PASSWORD" redis-cli -p "$SENTINEL_PORT" "$@"
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
    local timeout=${2:-30}
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
# It first waits for the failover-state field to become non-empty (failover started),
# then waits for it to become empty again (failover finished).
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
    local timeout=${2:-30}
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


# stop_process terminates a background process.
# Uses SIGKILL for test cleanup to avoid hanging on RDB saves.
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
