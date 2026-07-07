#!/usr/bin/env bash
set -euo pipefail

# Standalone E2E test for the redis-server reconfigure lifecycle action.
# Verifies that reconfigure applies changed parameters via CONFIG SET
# and persists them via CONFIG REWRITE.

export TEST_MASTER_PORT="${TEST_MASTER_PORT:-6396}"
export REDIS_CLUSTER_ID="reconfigure-e2e"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# shellcheck source=../redis-config-persistence/lib/common.sh
source "${SCRIPT_DIR}/../redis-config-persistence/lib/common.sh"
# shellcheck source=../redis-config-persistence/lib/assert.sh
source "${SCRIPT_DIR}/../redis-config-persistence/lib/assert.sh"
# shellcheck source=../../../scripts/helper.sh
source "${PROJECT_ROOT}/scripts/helper.sh"

echo "=== E2E: reconfigure applies parameters and persists via CONFIG REWRITE ==="

check_redis_version
check_port "$MASTER_PORT"

create_work_dir >/dev/null
INSTANCE_DIR="$WORK_DIR/master"

create_redis_template "$INSTANCE_DIR"
create_redis_runtime "$INSTANCE_DIR" "$MASTER_PORT"

echo "Step 1: start Redis instance"
start_redis_server "$INSTANCE_DIR"
wait_for_redis "$MASTER_PORT"

echo "Step 2: create op-replica operator user"
op_replica_pass=$(derive_password "op-replica")
redis_cli -p "$MASTER_PORT" ACL SETUSER op-replica on ">${op_replica_pass}" +@all >/dev/null

echo "Step 3: invoke reconfigure via lifecycle.sh"
(
  cd "$PROJECT_ROOT"
  KODA_COMPONENT_TYPE=redis-server \
  REDIS_CLUSTER_ID="$REDIS_CLUSTER_ID" \
  REDIS_PORT="$MASTER_PORT" \
  KODA_CONFIG_CHANGED_PARAMETERS='[{"key":"maxmemory","newValue":"536870912"}]' \
    ./scripts/lifecycle.sh reconfigure '{}'
)

echo "Step 4: verify running config updated"
maxmemory=$(redis_cli -p "$MASTER_PORT" CONFIG GET maxmemory | tail -1 | tr -d '\r')
assert_equals "536870912" "$maxmemory" "maxmemory in running config"

echo "Step 5: verify CONFIG REWRITE persisted the change"
assert_file_contains "$INSTANCE_DIR/redis-runtime.conf" "^maxmemory 512mb" "runtime.conf contains updated maxmemory"

echo "=== E2E: reconfigure-server PASSED ==="
