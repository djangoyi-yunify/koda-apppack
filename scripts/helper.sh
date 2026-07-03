#!/usr/bin/env bash

# Shared helper functions for Redis AppPack lifecycle actions.
# This file is sourced by scripts/lifecycle.sh and action function libraries.

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

# Environment / derivation helpers.
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

# redis-cli execution helpers.

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
