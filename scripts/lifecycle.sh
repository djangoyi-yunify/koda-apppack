#!/usr/bin/env bash
set -euo pipefail

# Unified lifecycle action script for Redis AppPack.
# Usage: lifecycle.sh <action> <json-params>
# For postProvision, json-params is '{}' and all runtime info comes from env vars.

ACTION="${1:-}"
PARAMS="${2:-{}}"

# Default ports.
REDIS_PORT="${REDIS_PORT:-6379}"
SENTINEL_PORT="${SENTINEL_PORT:-26379}"

# Operator usernames created by init.sh.
REDIS_OPERATOR_USER="op-replica"
SENTINEL_OPERATOR_USER="op-sentinel"

# JSON output helpers.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

fail_json() {
  local message="$1"
  local error="${2:-}"
  printf '{"status":"failure","message":"%s","error":"%s"}\n' \
    "$(json_escape "$message")" \
    "$(json_escape "$error")"
  exit 1
}

success_json() {
  local message="$1"
  printf '{"status":"success","message":"%s","error":""}\n' \
    "$(json_escape "$message")"
  exit 0
}

derive_password() {
  local username="$1"
  printf '%s' "${REDIS_CLUSTER_ID}:${username}" | sha256sum | awk '{print $1}'
}

require_env() {
  local name="$1"
  local value="${!name:-}"
  if [[ -z "$value" ]]; then
    fail_json "Missing required environment variable: ${name}" ""
  fi
}

derive_ordinal() {
  local hostname="$1"
  if [[ ! "$hostname" =~ -([0-9]+)$ ]]; then
    fail_json "Unable to derive ordinal from HOSTNAME: ${hostname}" ""
  fi
  printf '%s' "${BASH_REMATCH[1]}"
}

# Run a redis-cli command and return its stdout.
# The caller can capture the exit code via `output=$(redis_cli_exec ...) || rc=$?`.
redis_cli_exec() {
  local port="$1"
  local user="$2"
  local pass="$3"
  shift 3
  local tmpfile
  tmpfile=$(mktemp)
  redis-cli -h 127.0.0.1 -p "$port" --user "$user" --pass "$pass" --no-auth-warning "$@" > "$tmpfile" 2>&1
  local rc=$?
  cat "$tmpfile"
  rm -f "$tmpfile"
  return $rc
}

# Check whether a redis-cli execution failed either by exit code or by containing an ERR response.
redis_cli_failed() {
  local rc="$1"
  local output="$2"
  if [[ $rc -ne 0 || "$output" == *"ERR"* ]]; then
    return 0
  fi
  return 1
}

provision_server() {
  require_env "KODA_HEADLESS_SERVICE"
  require_env "HOSTNAME"

  local ordinal
  ordinal=$(derive_ordinal "${HOSTNAME}")

  if [[ "$ordinal" == "0" ]]; then
    success_json "Primary node (ordinal 0), no replicaof needed"
  fi

  local master_fqdn="redis-server-0.${KODA_HEADLESS_SERVICE}"
  local replica_pass
  replica_pass=$(derive_password "$REDIS_OPERATOR_USER")

  local output rc=0
  output=$(redis_cli_exec "$REDIS_PORT" "$REDIS_OPERATOR_USER" "$replica_pass" REPLICAOF "$master_fqdn" "$REDIS_PORT") || rc=$?
  if redis_cli_failed "$rc" "$output"; then
    fail_json "Failed to execute REPLICAOF ${master_fqdn} ${REDIS_PORT}" "$output"
  fi

  success_json "Configured as replica of ${master_fqdn}:${REDIS_PORT}"
}

provision_sentinel() {
  require_env "KODA_HEADLESS_SERVICE"
  require_env "KODA_SENTINEL_REPLICAS"

  local replicas="$KODA_SENTINEL_REPLICAS"
  if ! [[ "$replicas" =~ ^[0-9]+$ ]]; then
    fail_json "KODA_SENTINEL_REPLICAS must be a non-negative integer" "got: ${replicas}"
  fi

  local quorum=$((replicas / 2 + 1))
  local master_name="${REDIS_CLUSTER_ID}-master"
  local master_fqdn="redis-server-0.${KODA_HEADLESS_SERVICE}"
  local sentinel_pass
  sentinel_pass=$(derive_password "$SENTINEL_OPERATOR_USER")
  local replica_pass
  replica_pass=$(derive_password "$REDIS_OPERATOR_USER")

  # Check if the master is already monitored.
  local master_info rc=0
  master_info=$(redis_cli_exec "$SENTINEL_PORT" "$SENTINEL_OPERATOR_USER" "$sentinel_pass" SENTINEL MASTER "$master_name") || rc=$?

  if redis_cli_failed "$rc" "$master_info"; then
    if [[ "$master_info" == *"No such master"* ]]; then
      local output monitor_rc=0
      output=$(redis_cli_exec "$SENTINEL_PORT" "$SENTINEL_OPERATOR_USER" "$sentinel_pass" \
        SENTINEL MONITOR "$master_name" "$master_fqdn" "$REDIS_PORT" "$quorum") || monitor_rc=$?
      if redis_cli_failed "$monitor_rc" "$output" && [[ "$output" != *"Duplicate master"* ]]; then
        fail_json "Failed to execute SENTINEL MONITOR" "$output"
      fi
    else
      fail_json "Failed to query SENTINEL MASTER" "$master_info"
    fi
  fi

  # Configure authentication for Sentinel to connect to the master.
  local auth_output auth_rc=0
  auth_output=$(redis_cli_exec "$SENTINEL_PORT" "$SENTINEL_OPERATOR_USER" "$sentinel_pass" \
    SENTINEL SET "$master_name" auth-user "$REDIS_OPERATOR_USER") || auth_rc=$?
  if redis_cli_failed "$auth_rc" "$auth_output"; then
    fail_json "Failed to set auth-user" "$auth_output"
  fi

  auth_output=$(redis_cli_exec "$SENTINEL_PORT" "$SENTINEL_OPERATOR_USER" "$sentinel_pass" \
    SENTINEL SET "$master_name" auth-pass "$replica_pass") || auth_rc=$?
  if redis_cli_failed "$auth_rc" "$auth_output"; then
    fail_json "Failed to set auth-pass" "$auth_output"
  fi

  success_json "Sentinel is monitoring ${master_name} (${master_fqdn}:${REDIS_PORT}) with quorum ${quorum}"
}

post_provision() {
  require_env "KODA_COMPONENT_TYPE"

  case "$KODA_COMPONENT_TYPE" in
    redis-server)
      provision_server
      ;;
    redis-sentinel)
      provision_sentinel
      ;;
    *)
      fail_json "Unknown component type: ${KODA_COMPONENT_TYPE}" ""
      ;;
  esac
}

case "$ACTION" in
  postProvision)
    post_provision
    ;;
  roleProbe|availableProbe|switchover|memberJoin|memberLeave|reconfigure)
    fail_json "Action '${ACTION}' is not implemented in this change" ""
    ;;
  "")
    fail_json "Missing action name in \$1" ""
    ;;
  *)
    fail_json "Unknown action: ${ACTION}" ""
    ;;
esac
