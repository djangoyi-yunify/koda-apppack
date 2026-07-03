# postProvision action implementation for Redis AppPack.
# Sourced by scripts/lifecycle.sh; defines only functions with no top-level execution code.

postProvision() {
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
