#!/usr/bin/env bash
set -euo pipefail

# Use a dedicated port so task-01 can run in the same non-cleanup phase as task-02/03.
export TEST_MASTER_PORT="${TEST_MASTER_PORT:-6399}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/assert.sh
source "${SCRIPT_DIR}/lib/assert.sh"

echo "=== Task 01: maxmemory CONFIG REWRITE isolation ==="

check_redis_version
check_port "$MASTER_PORT"

create_work_dir >/dev/null
INSTANCE_DIR="$WORK_DIR/master"

create_redis_template "$INSTANCE_DIR"
create_redis_runtime "$INSTANCE_DIR" "$MASTER_PORT"

echo "Step 1: start Redis with maxmemory only in template"
start_redis_server "$INSTANCE_DIR"
wait_for_redis "$MASTER_PORT"

echo "Step 2: CONFIG SET maxmemory 512mb and CONFIG REWRITE"
redis_cli -p "$MASTER_PORT" CONFIG SET maxmemory "$((512*1024*1024))" >/dev/null
redis_cli -p "$MASTER_PORT" CONFIG REWRITE >/dev/null

echo "Step 3: verify maxmemory changes in config files"
assert_file_contains "$INSTANCE_DIR/redis-runtime.conf" "^maxmemory 512mb" "runtime.conf contains updated maxmemory"
assert_file_contains "$INSTANCE_DIR/redis-template.conf" "^maxmemory 256mb" "template.conf retains original maxmemory"

echo "=== Task 01 PASSED ==="
