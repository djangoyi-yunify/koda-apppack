#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/assert.sh
source "${SCRIPT_DIR}/lib/assert.sh"

echo "=== Task 02: Redis replica config persistence ==="

check_redis_version
check_all_ports

create_work_dir >/dev/null
MASTER_DIR="$WORK_DIR/master"
REPLICA_DIR="$WORK_DIR/replica"

create_redis_template "$MASTER_DIR"
create_redis_runtime "$MASTER_DIR" "$MASTER_PORT"
create_redis_template "$REPLICA_DIR"
create_redis_runtime "$REPLICA_DIR" "$REPLICA_PORT"

echo "Step 1: start master and replica"
start_redis_server "$MASTER_DIR"
wait_for_redis "$MASTER_PORT"
start_redis_server "$REPLICA_DIR"
wait_for_redis "$REPLICA_PORT"

echo "Step 2: build replication via redis-cli and CONFIG REWRITE"
redis_cli -p "$REPLICA_PORT" CONFIG SET masterauth "$REDIS_PASSWORD" >/dev/null
redis_cli -p "$REPLICA_PORT" REPLICAOF 127.0.0.1 "$MASTER_PORT" >/dev/null
wait_for_replica_sync "$REPLICA_PORT"
redis_cli -p "$REPLICA_PORT" CONFIG REWRITE >/dev/null

assert_file_contains "$REPLICA_DIR/redis-runtime.conf" "^replicaof 127\.0\.0\.1 ${MASTER_PORT}" "runtime.conf contains replicaof"
assert_file_contains "$REPLICA_DIR/redis-runtime.conf" "^masterauth.*${REDIS_PASSWORD}" "runtime.conf contains masterauth"
assert_file_not_contains "$REPLICA_DIR/redis-template.conf" "replicaof" "template.conf is not polluted with replicaof"

echo "Step 3: restart replica and verify role recovery"
stop_process "${PIDS[1]}"
PIDS=("${PIDS[0]}")
start_redis_server "$REPLICA_DIR"
wait_for_redis "$REPLICA_PORT"
wait_for_replica_sync "$REPLICA_PORT"
assert_role "$REPLICA_PORT" "slave"

echo "Step 4: start Sentinel and verify authentication"
create_sentinel_config "$WORK_DIR/sentinel"
start_sentinel "$WORK_DIR/sentinel"
wait_for_sentinel

# Negative auth check: without password, Sentinel commands should fail.
auth_output=$(REDISCLI_AUTH="" redis-cli -p "$SENTINEL_PORT" SENTINEL master "$MASTER_NAME" 2>&1 || true)
if ! echo "$auth_output" | grep -qE "NOAUTH|Authentication required"; then
    assert_fail "Sentinel accepted command without password: ${auth_output}"
fi
echo "OK: Sentinel rejects unauthenticated commands"

# Positive auth check: with password, Sentinel can see the master.
sentinel_cli SENTINEL master "$MASTER_NAME" >/dev/null
echo "OK: Sentinel accepts authenticated commands"

wait_for_sentinel_slaves 1

echo "Step 5: trigger Sentinel failover and verify replicaof update"
failover_output=$(sentinel_cli SENTINEL failover "$MASTER_NAME" 2>&1 || true)
echo "SENTINEL FAILOVER output: ${failover_output}"
wait_for_sentinel_failover_complete
wait_for_failover "$REPLICA_PORT"
redis_cli -p "$REPLICA_PORT" CONFIG REWRITE >/dev/null
assert_file_not_contains "$REPLICA_DIR/redis-runtime.conf" "^replicaof 127\.0\.0\.1 ${MASTER_PORT}" "runtime.conf no longer contains old replicaof"

echo "=== Task 02 PASSED ==="
