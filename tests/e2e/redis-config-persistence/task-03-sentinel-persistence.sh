#!/usr/bin/env bash
set -euo pipefail

# Use dedicated ports so task-03 can run in the same non-cleanup phase as task-02.
export TEST_MASTER_PORT="${TEST_MASTER_PORT:-6381}"
export TEST_REPLICA_PORT="${TEST_REPLICA_PORT:-6382}"
export TEST_SENTINEL_PORT="${TEST_SENTINEL_PORT:-26380}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/assert.sh
source "${SCRIPT_DIR}/lib/assert.sh"

echo "=== Task 03: Sentinel persistence ==="

check_redis_version
check_all_ports

create_work_dir >/dev/null
MASTER_DIR="$WORK_DIR/master"
REPLICA_DIR="$WORK_DIR/replica"
SENTINEL_DIR="$WORK_DIR/sentinel"

create_redis_template "$MASTER_DIR"
create_redis_runtime "$MASTER_DIR" "$MASTER_PORT"
create_redis_template "$REPLICA_DIR"
create_redis_runtime "$REPLICA_DIR" "$REPLICA_PORT"

echo "Step 1: start master, replica and Sentinel"
start_redis_server "$MASTER_DIR"
wait_for_redis "$MASTER_PORT"
start_redis_server "$REPLICA_DIR"
wait_for_redis "$REPLICA_PORT"
redis_cli -p "$REPLICA_PORT" CONFIG SET masterauth "$REDIS_PASSWORD" >/dev/null
redis_cli -p "$REPLICA_PORT" REPLICAOF 127.0.0.1 "$MASTER_PORT" >/dev/null
wait_for_replica_sync "$REPLICA_PORT"

create_sentinel_config "$SENTINEL_DIR"
start_sentinel "$SENTINEL_DIR"
wait_for_sentinel
wait_for_sentinel_slaves 1

echo "Step 2: first failover to establish sentinel.conf baseline"
sentinel_cli SENTINEL failover "$MASTER_NAME" >/dev/null
wait_for_failover "$REPLICA_PORT"
wait_for_sentinel_failover_complete

# Read baseline values from sentinel.conf.
baseline_epoch=$(grep -E "^sentinel config-epoch" "$SENTINEL_DIR/sentinel.conf" | awk '{print $4}' | tr -d '\r')
assert_file_contains "$SENTINEL_DIR/sentinel.conf" "^sentinel known-replica ${MASTER_NAME}" "sentinel.conf contains known-replica after first failover"
if [[ -z "$baseline_epoch" ]]; then
    assert_fail "could not read config-epoch from sentinel.conf"
fi
echo "OK: baseline config-epoch is ${baseline_epoch}"

echo "Step 3: second failover and verify sentinel.conf updates"
sentinel_cli SENTINEL failover "$MASTER_NAME" >/dev/null
wait_for_sentinel_failover_complete
# After the second failover, the original replica (now replica again) should be recorded as known-replica.
assert_config_epoch_gt "$baseline_epoch"
assert_known_replica "$SENTINEL_DIR/sentinel.conf" "127.0.0.1" "$REPLICA_PORT"

echo "Step 4: restart Sentinel and verify topology recovery"
# Capture the current master address before restart.
# After the second failover the original master (6379) is master again.
current_master_port=$(sentinel_cli SENTINEL get-master-addr-by-name "$MASTER_NAME" | tail -1 | tr -d '\r')
assert_equals "$MASTER_PORT" "$current_master_port" "Sentinel reports original master as master before restart"

stop_process "${PIDS[2]}"
PIDS=("${PIDS[0]}" "${PIDS[1]}")
start_sentinel "$SENTINEL_DIR"
wait_for_sentinel

recovered_master_port=$(sentinel_cli SENTINEL get-master-addr-by-name "$MASTER_NAME" | tail -1 | tr -d '\r')
assert_equals "$MASTER_PORT" "$recovered_master_port" "Sentinel recovers master topology after restart"

echo "=== Task 03 PASSED ==="
