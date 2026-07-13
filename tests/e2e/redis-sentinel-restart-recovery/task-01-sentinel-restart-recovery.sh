#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/assert.sh
source "${SCRIPT_DIR}/lib/assert.sh"

echo "=== Task 01: Sentinel failover and old master restart recovery ==="

check_redis_version
check_all_ports

create_work_dir >/dev/null
MASTER_DIR="$WORK_DIR/master"
REPLICA_DIR="$WORK_DIR/replica"
SENTINEL_DIR="$WORK_DIR/sentinel"

echo "Step 1: create redis-template.conf for master and replica"
create_redis_template "$MASTER_DIR"
create_redis_template "$REPLICA_DIR"

echo "Step 2: run init.sh server to generate initial runtime configs"
run_init_server_first_creation "$MASTER_DIR" "redis-server-0" "$MASTER_PORT"
run_init_server_first_creation "$REPLICA_DIR" "redis-server-1" "$REPLICA_PORT"

# The local E2E environment runs both Redis instances on the same host, so the
# actual listen ports differ. Append them after init.sh has created the files.
echo "port $MASTER_PORT" >> "$MASTER_DIR/redis-runtime.conf"
echo "port $REPLICA_PORT" >> "$REPLICA_DIR/redis-runtime.conf"
# Make the replica follow the master at startup.
echo "replicaof 127.0.0.1 $MASTER_PORT" >> "$REPLICA_DIR/redis-runtime.conf"

echo "Step 3: start master and replica"
start_redis_server "$MASTER_DIR"
wait_for_redis "$MASTER_PORT"
start_redis_server "$REPLICA_DIR"
wait_for_replica_sync "$REPLICA_PORT"
echo "OK: master on port $MASTER_PORT, replica on port $REPLICA_PORT"

echo "Step 4: start Sentinel monitoring the master"
create_sentinel_config "$SENTINEL_DIR"
start_sentinel "$SENTINEL_DIR"
wait_for_sentinel
wait_for_sentinel_slaves 1
echo "OK: Sentinel is monitoring $MASTER_NAME"

echo "Step 5: trigger Sentinel failover so the replica becomes the new master"
sentinel_cli SENTINEL failover "$MASTER_NAME" >/dev/null
wait_for_sentinel_failover_complete
wait_for_failover "$REPLICA_PORT"
echo "OK: replica on port $REPLICA_PORT is now the master"

echo "Step 6: stop the old master process (redis-server-0)"
stop_process "${PIDS[0]}"
PIDS=("${PIDS[1]}" "${PIDS[2]}")
echo "OK: old master stopped"

echo "Step 7: simulate old master Pod restart by running init.sh server"
run_init_server_restart "$MASTER_DIR" "redis-server-0" "$MASTER_PORT"
echo "OK: init.sh server completed on old master directory"

echo "Step 8: verify init.sh updated replicaof in redis-runtime.conf"
assert_file_contains "$MASTER_DIR/redis-runtime.conf" "^replicaof 127\.0\.0\.1 ${REPLICA_PORT}" "old master runtime.conf points to new master"

echo "Step 9: restart the old master with the updated runtime config"
start_redis_server "$MASTER_DIR"
wait_for_redis "$MASTER_PORT"
wait_for_replica_sync "$MASTER_PORT"

echo "Step 10: verify old master rejoined as a replica of the new master"
assert_role "$MASTER_PORT" "slave"
assert_replica_of "$MASTER_PORT" "127.0.0.1" "$REPLICA_PORT"

echo "=== Task 01 PASSED ==="
