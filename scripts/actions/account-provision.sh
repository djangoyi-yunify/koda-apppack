# shellcheck shell=bash
# accountProvision action implementation for Redis AppPack.
# Sourced by scripts/lifecycle.sh; defines only functions with no top-level execution code.

# Extract a string value for a given key from a flat JSON object.
# Only supports string values without escaped quotes.
# Returns 0 if the key is found, 1 otherwise.
_json_get_string() {
  local json="$1"
  local key="$2"
  local pattern="\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
  if [[ "$json" =~ $pattern ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

accountProvision() {
  local params="$1"

  require_env "KODA_COMPONENT_TYPE"
  require_env "REDIS_CLUSTER_ID"

  local name="" password="" statement=""

  if ! name=$(_json_get_string "$params" "name"); then
    fail_json "Missing required field: name" ""
  fi

  if ! statement=$(_json_get_string "$params" "statement"); then
    fail_json "Missing required field: statement" ""
  fi

  if [[ "$statement" != "delete" ]]; then
    if ! password=$(_json_get_string "$params" "password"); then
      fail_json "Missing required field: password for non-delete operation" ""
    fi
  fi

  # Validate statement for accidental command injection.
  if [[ "$statement" == *$'\n'* || "$statement" == *';'* ]]; then
    fail_json "Invalid statement: must not contain newline or semicolon" "$statement"
  fi

  if [[ "$statement" == "ACL "* ]]; then
    fail_json "Invalid statement: must not start with 'ACL '" "$statement"
  fi

  # Select target port and operator user based on component type.
  local target_port operator_user operator_pass
  case "$KODA_COMPONENT_TYPE" in
    redis-server)
      target_port="$REDIS_PORT"
      operator_user="$REDIS_OPERATOR_USER"
      ;;
    redis-sentinel)
      target_port="$SENTINEL_PORT"
      operator_user="$SENTINEL_OPERATOR_USER"
      ;;
    *)
      fail_json "Unknown component type: ${KODA_COMPONENT_TYPE}" ""
      ;;
  esac

  operator_pass=$(derive_password "$operator_user")

  local output rc=0

  if [[ "$statement" == "delete" ]]; then
    output=$(redis_cli_exec "$target_port" "$operator_user" "$operator_pass" ACL DELUSER "$name") || rc=$?
    if redis_cli_failed "$rc" "$output"; then
      fail_json "Failed to delete user ${name}" "$output"
    fi
  else
    local rules="$statement"
    if [[ -z "$rules" ]]; then
      if [[ "$name" == "default" ]]; then
        rules="~* &* +@all"
      else
        rules="~* +@read +@write +@connection"
      fi
    fi

    local rule_array
    read -ra rule_array <<< "$rules"

    output=$(redis_cli_exec "$target_port" "$operator_user" "$operator_pass" \
      ACL SETUSER "$name" on ">${password}" "${rule_array[@]}") || rc=$?
    if redis_cli_failed "$rc" "$output"; then
      fail_json "Failed to create/update user ${name}" "$output"
    fi
  fi

  output=$(redis_cli_exec "$target_port" "$operator_user" "$operator_pass" ACL SAVE) || rc=$?
  if redis_cli_failed "$rc" "$output"; then
    fail_json "Failed to persist ACL changes" "$output"
  fi

  if [[ "$statement" == "delete" ]]; then
    success_json "User ${name} deleted and ACL saved"
  else
    success_json "User ${name} provisioned and ACL saved"
  fi
}
