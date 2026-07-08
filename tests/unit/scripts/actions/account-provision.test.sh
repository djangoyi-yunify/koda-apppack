#!/usr/bin/env bash
set -euo pipefail

# Unit tests for scripts/actions/account-provision.sh.
# Each test runs in a subshell with a mocked redis-cli to verify command dispatch.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
HELPER="${PROJECT_ROOT}/scripts/helper.sh"
ACCOUNT_PROVISION="${PROJECT_ROOT}/scripts/actions/account-provision.sh"

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
  export REDIS_OPERATOR_USER="op-replica"
  export SENTINEL_OPERATOR_USER="op-sentinel"
  export KODA_ACCOUNT_NAME="app"
  export KODA_ACCOUNT_PASSWORD="secret"
  export KODA_ACCOUNT_STATEMENT="~* +@read +@write +@connection"
}

# Test: accountProvision reads from environment variables and dispatches ACL SETUSER + ACL SAVE.
test_env_var_path() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local log="${tmpdir}/redis-cli.log"
  export FAKE_REDIS_CLI_LOG="${log}"
  make_fake_redis_cli "${tmpdir}"
  export PATH="${tmpdir}:${PATH}"

  setup_env
  source "${HELPER}"
  source "${ACCOUNT_PROVISION}"

  local output
  output=$(accountProvision)

  if [[ "$output" != *'"status":"success"'* ]]; then
    echo "expected success output, got: ${output}"
    return 1
  fi

  grep -qF "ACL SETUSER app on >secret ~* +@read +@write +@connection" "${log}" || {
    echo "missing ACL SETUSER"; cat "${log}"; return 1;
  }
  grep -qF "ACL SAVE" "${log}" || {
    echo "missing ACL SAVE"; cat "${log}"; return 1;
  }

  rm -rf "${tmpdir}"
}

# Test: accountProvision accepts an optional JSON argument for manual testing.
test_json_argument_path() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local log="${tmpdir}/redis-cli.log"
  export FAKE_REDIS_CLI_LOG="${log}"
  make_fake_redis_cli "${tmpdir}"
  export PATH="${tmpdir}:${PATH}"

  export KODA_COMPONENT_TYPE="redis-server"
  export REDIS_CLUSTER_ID="test-cluster"
  export REDIS_PORT="6379"
  export REDIS_OPERATOR_USER="op-replica"
  export SENTINEL_OPERATOR_USER="op-sentinel"
  unset KODA_ACCOUNT_NAME KODA_ACCOUNT_PASSWORD KODA_ACCOUNT_STATEMENT
  source "${HELPER}"
  source "${ACCOUNT_PROVISION}"

  local output
  output=$(accountProvision '{"name":"json-app","password":"json-secret","statement":"~* +@all"}')

  if [[ "$output" != *'"status":"success"'* ]]; then
    echo "expected success output, got: ${output}"
    return 1
  fi

  grep -qF "ACL SETUSER json-app on >json-secret ~* +@all" "${log}" || {
    echo "missing ACL SETUSER from JSON"; cat "${log}"; return 1;
  }
  grep -qF "ACL SAVE" "${log}" || {
    echo "missing ACL SAVE"; cat "${log}"; return 1;
  }

  rm -rf "${tmpdir}"
}

# Test: accountProvision fails when a required environment variable is missing.
test_missing_env_var_fails() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local log="${tmpdir}/redis-cli.log"
  export FAKE_REDIS_CLI_LOG="${log}"
  make_fake_redis_cli "${tmpdir}"
  export PATH="${tmpdir}:${PATH}"

  export KODA_COMPONENT_TYPE="redis-server"
  export REDIS_CLUSTER_ID="test-cluster"
  export REDIS_PORT="6379"
  export REDIS_OPERATOR_USER="op-replica"
  export SENTINEL_OPERATOR_USER="op-sentinel"
  export KODA_ACCOUNT_NAME="app"
  unset KODA_ACCOUNT_PASSWORD
  export KODA_ACCOUNT_STATEMENT="~* +@all"
  source "${HELPER}"
  source "${ACCOUNT_PROVISION}"

  local output rc=0
  output=$(accountProvision) || rc=$?

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

# Test: accountProvision delete operation uses ACL DELUSER and does not require password.
test_delete_operation() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local log="${tmpdir}/redis-cli.log"
  export FAKE_REDIS_CLI_LOG="${log}"
  make_fake_redis_cli "${tmpdir}"
  export PATH="${tmpdir}:${PATH}"

  export KODA_COMPONENT_TYPE="redis-server"
  export REDIS_CLUSTER_ID="test-cluster"
  export REDIS_PORT="6379"
  export REDIS_OPERATOR_USER="op-replica"
  export SENTINEL_OPERATOR_USER="op-sentinel"
  export KODA_ACCOUNT_NAME="to-delete"
  unset KODA_ACCOUNT_PASSWORD
  export KODA_ACCOUNT_STATEMENT="delete"
  source "${HELPER}"
  source "${ACCOUNT_PROVISION}"

  local output
  output=$(accountProvision)

  if [[ "$output" != *'"status":"success"'* ]]; then
    echo "expected success output, got: ${output}"
    return 1
  fi

  grep -qF "ACL DELUSER to-delete" "${log}" || {
    echo "missing ACL DELUSER"; cat "${log}"; return 1;
  }
  grep -qF "ACL SAVE" "${log}" || {
    echo "missing ACL SAVE"; cat "${log}"; return 1;
  }

  rm -rf "${tmpdir}"
}

echo "=== account-provision unit tests ==="
run_test test_env_var_path
run_test test_json_argument_path
run_test test_missing_env_var_fails
run_test test_delete_operation

echo ""
echo "=== All account-provision unit tests passed ==="
