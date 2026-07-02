#!/usr/bin/env bash
set -euo pipefail

# assert_equals fails if two values are not equal.
assert_equals() {
    local expected=$1
    local actual=$2
    local message=${3:-}
    if [[ "$expected" != "$actual" ]]; then
        echo "ASSERT FAIL: expected '${expected}', got '${actual}'${message:+ (${message})}"
        exit 1
    fi
    echo "OK: ${message:-assert_equals}"
}

# assert_file_contains fails if the file does not contain the given pattern.
assert_file_contains() {
    local file=$1
    local pattern=$2
    local message=${3:-}
    if ! grep -qE "$pattern" "$file"; then
        echo "ASSERT FAIL: file '${file}' does not contain pattern '${pattern}'${message:+ (${message})}"
        exit 1
    fi
    echo "OK: ${message:-assert_file_contains}"
}

# assert_file_not_contains fails if the file contains the given pattern.
assert_file_not_contains() {
    local file=$1
    local pattern=$2
    local message=${3:-}
    if grep -qE "$pattern" "$file"; then
        echo "ASSERT FAIL: file '${file}' contains pattern '${pattern}'${message:+ (${message})}"
        exit 1
    fi
    echo "OK: ${message:-assert_file_not_contains}"
}

# assert_role fails if the Redis instance on the given port does not have the expected role.
assert_role() {
    local port=$1
    local expected_role=$2
    local actual_role
    actual_role=$(redis_cli -p "$port" INFO replication | awk -F: '/^role:/{print $2}' | tr -d '\r')
    assert_equals "$expected_role" "$actual_role" "role on port ${port}"
}

# assert_config_epoch fails if the Sentinel config-epoch is not greater than the given baseline.
assert_config_epoch_gt() {
    local baseline=$1
    local actual
    actual=$(sentinel_cli SENTINEL master "$MASTER_NAME" | awk '/^config-epoch$/{getline; print}' | tr -d '\r')
    if [[ -z "$actual" || "$actual" -le "$baseline" ]]; then
        echo "ASSERT FAIL: expected config-epoch > ${baseline}, got '${actual}'"
        exit 1
    fi
    echo "OK: config-epoch ${actual} > ${baseline}"
}

# assert_known_replica fails if sentinel.conf does not contain known-replica for the given host/port.
assert_known_replica() {
    local sentinel_conf=$1
    local host=$2
    local port=$3
    if ! grep -qE "sentinel known-replica ${MASTER_NAME} ${host} ${port}" "$sentinel_conf"; then
        echo "ASSERT FAIL: sentinel.conf does not contain known-replica ${host}:${port}"
        exit 1
    fi
    echo "OK: known-replica ${host}:${port} found"
}

# assert_fail fails the test with the given message.
assert_fail() {
    echo "ASSERT FAIL: $1"
    exit 1
}
