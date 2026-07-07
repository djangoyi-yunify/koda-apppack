#!/usr/bin/env bash
set -euo pipefail

# Runner for the redis-reconfigure E2E test suite.
# Only covers the reconfigure lifecycle action; does not run unrelated suites.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Redis reconfigure E2E test suite ==="
bash "${SCRIPT_DIR}/reconfigure-server.sh"
echo ""
echo "=== Redis reconfigure E2E test suite PASSED ==="
