#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Running unit tests ==="

bash "${SCRIPT_DIR}/scripts/actions/reconfigure.test.sh"
bash "${SCRIPT_DIR}/scripts/actions/account-provision.test.sh"

echo ""
echo "=== All unit tests passed ==="
