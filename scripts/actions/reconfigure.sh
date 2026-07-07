# shellcheck shell=bash
# reconfigure action implementation for Redis AppPack.
# Sourced by scripts/lifecycle.sh; defines only functions with no top-level execution code.
# NOTE: reconfigure currently supports only redis-server; redis-sentinel is out of scope
# because Sentinel does not support standard CONFIG SET.

# Default value table for removed Redis parameters.
# Add new entries here when supporting additional reloadable config keys.
declare -A _REDIS_RECONFIGURE_DEFAULTS=(
  ["maxmemory"]="0"
  ["maxmemory-policy"]="noeviction"
  ["loglevel"]="notice"
  ["timeout"]="0"
  ["tcp-keepalive"]="300"
  ["client-output-buffer-limit"]="normal 0 0 0"
  ["databases"]="16"
  ["lua-time-limit"]="5000"
  ["slowlog-log-slower-than"]="10000"
  ["slowlog-max-len"]="128"
)

reconfigure() {
  local params="${1:-${KODA_CONFIG_CHANGED_PARAMETERS:-}}"

  require_env "KODA_COMPONENT_TYPE"
  require_env "REDIS_CLUSTER_ID"

  if [[ "$KODA_COMPONENT_TYPE" != "redis-server" ]]; then
    fail_json "reconfigure is only supported for redis-server, got: ${KODA_COMPONENT_TYPE}" ""
  fi

  if ! command -v jq >/dev/null 2>&1; then
    fail_json "jq is required to parse changed parameters" "jq not found in PATH"
  fi

  local target_port="${REDIS_PORT:-6379}"
  local operator_user="op-replica"
  local operator_pass
  operator_pass=$(derive_password "$operator_user")

  # No parameters to apply is a successful no-op.
  if [[ -z "$params" || "$params" == "null" || "$params" == "[]" ]]; then
    success_json "No configuration parameters to apply"
  fi

  # Parse the JSON array once and validate structure.
  local items
  items=$(jq -c '.[]' <<< "$params" 2>&1) || {
    fail_json "Failed to parse KODA_CONFIG_CHANGED_PARAMETERS" "$items"
  }

  local item key value_type new_value output rc=0

  while IFS= read -r item; do
    key=$(jq -r '.key' <<< "$item" 2>&1) || {
      fail_json "Failed to extract parameter key" "$key"
    }

    if [[ -z "$key" ]]; then
      fail_json "Parameter key cannot be empty" "$item"
    fi

    value_type=$(jq -r '.newValue | type' <<< "$item" 2>&1) || {
      fail_json "Failed to determine parameter value type" "$value_type"
    }

    if [[ "$value_type" == "null" ]]; then
      # Removed parameter: restore default value from the lookup table.
      new_value="${_REDIS_RECONFIGURE_DEFAULTS[$key]:-}"
      if [[ -z "$new_value" ]]; then
        fail_json "Removed parameter has no known default: ${key}" ""
      fi
    else
      new_value=$(jq -r '.newValue' <<< "$item" 2>&1) || {
        fail_json "Failed to extract parameter value" "$new_value"
      }
    fi

    output=$(redis_cli_exec "$target_port" "$operator_user" "$operator_pass" CONFIG SET "$key" "$new_value") || rc=$?
    if redis_cli_failed "$rc" "$output"; then
      fail_json "Failed to apply parameter ${key}=${new_value}" "$output"
    fi
  done <<< "$items"

  # Persist running configuration to the main config file.
  output=$(redis_cli_exec "$target_port" "$operator_user" "$operator_pass" CONFIG REWRITE) || rc=$?
  if redis_cli_failed "$rc" "$output"; then
    fail_json "Failed to persist configuration via CONFIG REWRITE" "$output"
  fi

  success_json "Configuration parameters applied successfully"
}
