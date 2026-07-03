#!/usr/bin/env bash
set -euo pipefail

# Unified lifecycle action dispatcher for Redis AppPack.
# Usage: lifecycle.sh <action> <json-params>
# Loads shared helpers and action function libraries, then dispatches to the
# function matching the action named in $1.

ACTION="${1:-}"
PARAMS="${2:-{}}"

# Default ports.
REDIS_PORT="${REDIS_PORT:-6379}"
SENTINEL_PORT="${SENTINEL_PORT:-26379}"

# Operator usernames created by init.sh.
REDIS_OPERATOR_USER="op-replica"
SENTINEL_OPERATOR_USER="op-sentinel"

# Load shared helpers and action function libraries.
source scripts/helper.sh
source scripts/actions/post-provision.sh
source scripts/actions/role-probe.sh
source scripts/actions/available-probe.sh
source scripts/actions/switchover.sh
source scripts/actions/member-join.sh
source scripts/actions/member-leave.sh
source scripts/actions/reconfigure.sh

# Dispatch to the action function by name.
case "$ACTION" in
  postProvision)
    postProvision
    ;;
  roleProbe)
    roleProbe
    ;;
  availableProbe)
    availableProbe
    ;;
  switchover)
    switchover
    ;;
  memberJoin)
    memberJoin
    ;;
  memberLeave)
    memberLeave
    ;;
  reconfigure)
    reconfigure
    ;;
  "")
    fail_json "Missing action name in \$1" ""
    ;;
  *)
    fail_json "Unknown action: ${ACTION}" ""
    ;;
esac
