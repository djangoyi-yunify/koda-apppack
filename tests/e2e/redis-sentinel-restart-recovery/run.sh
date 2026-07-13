#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# full_cleanup kills any processes on the test ports and removes temp work dirs.
full_cleanup() {
    echo "Cleaning up test processes and temp dirs..."
    for port in "$MASTER_PORT" "$REPLICA_PORT" "$SENTINEL_PORT"; do
        if command -v fuser >/dev/null 2>&1; then
            fuser -k -9 "$port/tcp" >/dev/null 2>&1 || true
        elif command -v lsof >/dev/null 2>&1; then
            local pids
            pids=$(lsof -t -i TCP:"$port" 2>/dev/null || true)
            if [[ -n "$pids" ]]; then
                # shellcheck disable=SC2086
                kill -9 $pids 2>/dev/null || true
            fi
        fi
    done
    rm -rf /tmp/redis-sentinel-restart-e2e-*
    echo "Cleanup done."
}

run_task() {
    local task=$1
    local no_cleanup=${2:-0}
    echo ""
    echo "============================================"
    echo "Running: $task"
    echo "============================================"
    if [[ "$no_cleanup" == "1" ]]; then
        E2E_NO_CLEANUP=1 "$SCRIPT_DIR/$task"
    else
        "$SCRIPT_DIR/$task"
    fi
}

echo "=== Redis Sentinel restart recovery e2e test suite ==="
check_redis_version
check_all_ports

# Phase 1: run the task with self-cleanup.
run_task "task-01-sentinel-restart-recovery.sh" 0

echo ""
echo "=== Individual task passed ==="

# Cleanup before regression to ensure a clean starting state.
full_cleanup

# Phase 2: regression test. The task does NOT clean up so the final state can be inspected.
echo ""
echo "=== Starting regression test ==="
run_task "task-01-sentinel-restart-recovery.sh" 1

echo ""
echo "=== Regression test PASSED ==="
echo "Test processes and temp dirs are preserved for inspection."
echo "Temp dirs: /tmp/redis-sentinel-restart-e2e-*/"
echo "Ports: $MASTER_PORT, $REPLICA_PORT, $SENTINEL_PORT"

if [[ -t 0 ]]; then
    read -rp "Cleanup now? [y/N] " answer
    if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
        full_cleanup
    else
        echo "Cleanup skipped. Run 'pkill -9 -f redis-server; pkill -9 -f redis-sentinel; rm -rf /tmp/redis-sentinel-restart-e2e-*' to clean up manually."
    fi
elif [[ "${E2E_AUTO_CLEANUP:-}" == "1" ]]; then
    full_cleanup
else
    echo "Non-interactive mode: automatic cleanup disabled. Set E2E_AUTO_CLEANUP=1 to enable automatic cleanup."
fi
