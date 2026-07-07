#!/usr/bin/env bash
set -euo pipefail

# Unit tests for scripts/actions/reconfigure.sh.
# Each test runs in a subshell with a mocked redis-cli to verify command dispatch.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
HELPER="${PROJECT_ROOT}/scripts/helper.sh"
RECONFIGURE="${PROJECT_ROOT}/scripts/actions/reconfigure.sh"

# Run a named test function in a subshell so failures do not abort the suite.
run_test() {
  local name=$1
  echo ""
  echo "Running: ${name}"
  if ("${name}"); then
    echo "PASS: ${name}"
  else
    echo "FAIL: ${name}"
    exit 1
  fi
}

# Create a fake redis-cli in a temp dir that logs every invocation to FAKE_REDIS_CLI_LOG.
make_fake_redis_cli() {
  local dir=$1
  cat > "${dir}/redis-cli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_REDIS_CLI_LOG}"
echo "OK"
EOF
  chmod +x "${dir}/redis-cli"
}

# Setup environment common to all tests.
setup_env() {
  export KODA_COMPONENT_TYPE="redis-server"
  export REDIS_CLUSTER_ID="test-cluster"
  export REDIS_PORT="6379"
}

# Test: added/updated parameters result in CONFIG SET calls and CONFIG REWRITE.
test_config_set_add_update() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local log="${tmpdir}/redis-cli.log"
  export FAKE_REDIS_CLI_LOG="${log}"
  make_fake_redis_cli "${tmpdir}"
  export PATH="${tmpdir}:${PATH}"

  setup_env
  # shellcheck source=../../../../scripts/helper.sh
  source "${HELPER}"
  # shellcheck source=../../../../scripts/actions/reconfigure.sh
  source "${RECONFIGURE}"

  local output
  output=$(reconfigure '[{"key":"maxmemory","newValue":"536870912"},{"key":"loglevel","newValue":"debug"}]')

  if [[ "$output" != *'"status":"success"'* ]]; then
    echo "expected success output, got: ${output}"
    return 1
  fi

  grep -qF "CONFIG SET maxmemory 536870912" "${log}" || {
    echo "missing CONFIG SET maxmemory"; cat "${log}"; return 1;
  }
  grep -qF "CONFIG SET loglevel debug" "${log}" || {
    echo "missing CONFIG SET loglevel"; cat "${log}"; return 1;
  }
  grep -qF "CONFIG REWRITE" "${log}" || {
    echo "missing CONFIG REWRITE"; cat "${log}"; return 1;
  }

  rm -rf "${tmpdir}"
}

# Test: removed parameters use the defaults table.
test_removed_parameter_uses_default() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local log="${tmpdir}/redis-cli.log"
  export FAKE_REDIS_CLI_LOG="${log}"
  make_fake_redis_cli "${tmpdir}"
  export PATH="${tmpdir}:${PATH}"

  setup_env
  source "${HELPER}"
  source "${RECONFIGURE}"

  local output
  output=$(reconfigure '[{"key":"maxmemory","oldValue":"536870912","newValue":null}]')

  if [[ "$output" != *'"status":"success"'* ]]; then
    echo "expected success output, got: ${output}"
    return 1
  fi

  grep -qF "CONFIG SET maxmemory 0" "${log}" || {
    echo "missing CONFIG SET maxmemory 0"; cat "${log}"; return 1;
  }

  rm -rf "${tmpdir}"
}

# Test: non-redis-server component types are rejected before any redis-cli call.
test_unsupported_component_type() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local log="${tmpdir}/redis-cli.log"
  export FAKE_REDIS_CLI_LOG="${log}"
  make_fake_redis_cli "${tmpdir}"
  export PATH="${tmpdir}:${PATH}"

  export KODA_COMPONENT_TYPE=redis-sentinel
  export REDIS_CLUSTER_ID="test-cluster"
  source "${HELPER}"
  source "${RECONFIGURE}"

  local output rc=0
  output=$(reconfigure '[{"key":"loglevel","newValue":"debug"}]') || rc=$?

  if [[ $rc -eq 0 ]]; then
    echo "expected non-zero exit code, got 0"
    return 1
  fi
  if [[ "$output" != *'"status":"failure"'* ]]; then
    echo "expected failure output, got: ${output}"
    return 1
  fi
  if [[ -s "${log}" ]]; then
    echo "redis-cli should not have been invoked"; cat "${log}"; return 1
  fi

  rm -rf "${tmpdir}"
}

# Test: strict failure on CONFIG SET error.
test_config_set_error_fails() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local log="${tmpdir}/redis-cli.log"
  export FAKE_REDIS_CLI_LOG="${log}"

  cat > "${tmpdir}/redis-cli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_REDIS_CLI_LOG}"
echo "ERR Unknown parameter"
EOF
  chmod +x "${tmpdir}/redis-cli"
  export PATH="${tmpdir}:${PATH}"

  setup_env
  source "${HELPER}"
  source "${RECONFIGURE}"

  local output rc=0
  output=$(reconfigure '[{"key":"bind","newValue":"127.0.0.1"}]') || rc=$?

  if [[ $rc -eq 0 ]]; then
    echo "expected non-zero exit code, got 0"
    return 1
  fi
  if [[ "$output" != *'"status":"failure"'* ]]; then
    echo "expected failure output, got: ${output}"
    return 1
  fi

  rm -rf "${tmpdir}"
}

echo "=== reconfigure unit tests ==="
run_test test_config_set_add_update
run_test test_removed_parameter_uses_default
run_test test_unsupported_component_type
run_test test_config_set_error_fails

echo ""
echo "=== All reconfigure unit tests passed ==="
