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

# assert_replica_of fails if the Redis instance on the given port is not replicating
# from the expected host and port.
assert_replica_of() {
    local port=$1
    local expected_host=$2
    local expected_port=$3
    local info
    info=$(redis_cli -p "$port" INFO replication)
    local actual_host actual_port
    actual_host=$(echo "$info" | awk -F: '/^master_host:/{print $2}' | tr -d '\r')
    actual_port=$(echo "$info" | awk -F: '/^master_port:/{print $2}' | tr -d '\r')
    assert_equals "$expected_host" "$actual_host" "master_host on port ${port}"
    assert_equals "$expected_port" "$actual_port" "master_port on port ${port}"
}

# assert_fail fails the test with the given message.
assert_fail() {
    echo "ASSERT FAIL: $1"
    exit 1
}
