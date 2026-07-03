# redis-post-provision Specification

## Purpose

Define the `postProvision` lifecycle action for the Redis replication + Sentinel topology in the Redis AppPack, including the unified script interface, runtime behavior for `redis-server` and `redis-sentinel` components, and idempotency guarantees.
## Requirements
### Requirement: Unified lifecycle script entrypoint

The system SHALL provide a unified lifecycle action entrypoint at `scripts/lifecycle.sh`. The entrypoint SHALL source `scripts/helper.sh` and all action function libraries under `scripts/actions/`, then dispatch to the function matching the action named in `$1`.

#### Scenario: Script receives supported action name
- **WHEN** Koda invokes `/scripts/lifecycle.sh postProvision '{}'`
- **THEN** `lifecycle.sh` loads `helper.sh` and the action function libraries, then calls the `postProvision` function

#### Scenario: Script receives unsupported action name
- **WHEN** Koda invokes `/scripts/lifecycle.sh unknownAction '{}'`
- **THEN** `lifecycle.sh` outputs a failure JSON and exits with a non-zero code

### Requirement: Shared helper script

The system SHALL provide a shared helper script at `scripts/helper.sh` containing JSON output helpers, password derivation, redis-cli execution wrapper, and other utilities used by lifecycle action functions.

#### Scenario: Action function uses shared helper
- **GIVEN** `lifecycle.sh` has sourced `helper.sh` and loaded action function libraries
- **WHEN** the `postProvision` function calls `fail_json` or `derive_password`
- **THEN** the helper functions execute correctly without re-definition in the action script

### Requirement: Action function libraries

The system SHALL organize each lifecycle action implementation as a function within a dedicated file under `scripts/actions/`. Action script files SHALL be sourced by `lifecycle.sh` and SHALL not be executed directly.

#### Scenario: postProvision action is defined in its own file
- **WHEN** inspecting `scripts/actions/post-provision.sh`
- **THEN** it defines a `postProvision` function and contains no top-level execution code outside function definitions

#### Scenario: Action script is not standalone
- **WHEN** attempting to execute `scripts/actions/post-provision.sh` directly
- **THEN** it does not run as an independent entrypoint

### Requirement: postProvision input contract

The system SHALL accept action parameters via positional arguments only: `$1` for the action name and `$2` for JSON parameters. The `postProvision` action SHALL receive `{}` as `$2` and SHALL derive all required runtime information from environment variables.

#### Scenario: postProvision is invoked with empty parameters
- **WHEN** Koda invokes `/scripts/lifecycle.sh postProvision '{}'`
- **THEN** the script proceeds without requiring parameters in `$2`

### Requirement: postProvision output contract

The system SHALL output a JSON object to stdout with exactly the fields `status`, `message`, and `error`.

#### Scenario: Action succeeds
- **WHEN** the `postProvision` handler completes successfully
- **THEN** stdout contains `{"status":"success","message":"...","error":""}`

#### Scenario: Action fails
- **WHEN** the `postProvision` handler encounters an error
- **THEN** stdout contains `{"status":"failure","message":"...","error":"..."}` before the script exits non-zero

### Requirement: Error exit must produce JSON

The system SHALL ensure that any error path outputs a valid failure JSON to stdout before exiting with a non-zero code.

#### Scenario: Missing required environment variable
- **WHEN** a required environment variable is missing
- **THEN** the script outputs a failure JSON and exits non-zero

#### Scenario: Command execution fails
- **WHEN** a redis-cli command returns an error
- **THEN** the script outputs a failure JSON and exits non-zero

### Requirement: redis-server postProvision configures replication

For the `redis-server` component, the system SHALL execute `REPLICAOF <master-fqdn> <port>` on every instance except ordinal 0.

#### Scenario: Replica instance runs postProvision
- **GIVEN** `KODA_COMPONENT_TYPE=redis-server` and `HOSTNAME=redis-server-2`
- **WHEN** `postProvision` is invoked
- **THEN** the script executes `REPLICAOF redis-server-0.<headless-service> 6379`

#### Scenario: Primary instance runs postProvision
- **GIVEN** `KODA_COMPONENT_TYPE=redis-server` and `HOSTNAME=redis-server-0`
- **WHEN** `postProvision` is invoked
- **THEN** the script skips `REPLICAOF` and reports success

### Requirement: redis-server postProvision is idempotent

The system SHALL allow `postProvision` to be invoked multiple times on the same `redis-server` instance without adverse effects.

#### Scenario: Replica already configured
- **GIVEN** a replica has already executed `REPLICAOF`
- **WHEN** `postProvision` is invoked again
- **THEN** the script succeeds and the replica remains configured for the same primary

### Requirement: redis-sentinel postProvision configures monitoring

For the `redis-sentinel` component, the system SHALL configure Sentinel to monitor the Redis primary with quorum and authentication.

#### Scenario: Sentinel has not yet monitored the master
- **GIVEN** `KODA_COMPONENT_TYPE=redis-sentinel`
- **WHEN** `postProvision` is invoked
- **THEN** the script executes `SENTINEL MONITOR <master-name> <master-fqdn> 6379 <quorum>` followed by `SENTINEL SET auth-user op-replica` and `SENTINEL SET auth-pass <derived-pass>`

#### Scenario: Sentinel already monitors the master
- **GIVEN** `KODA_COMPONENT_TYPE=redis-sentinel` and Sentinel already monitors the master
- **WHEN** `postProvision` is invoked
- **THEN** the script skips `SENTINEL MONITOR` and refreshes auth settings

### Requirement: redis-sentinel postProvision handles concurrent execution

The system SHALL treat a concurrent `SENTINEL MONITOR` conflict as success when the master is already monitored.

#### Scenario: Concurrent postProvision on multiple sentinels
- **GIVEN** two sentinel instances execute `postProvision` concurrently for the same master
- **WHEN** one succeeds and the other receives an already-monitored error
- **THEN** both executions report success

### Requirement: Quorum derivation

The system SHALL derive Sentinel quorum from `KODA_SENTINEL_REPLICAS` using integer division: `quorum = (replicas / 2) + 1`.

#### Scenario: Three sentinel replicas
- **GIVEN** `KODA_SENTINEL_REPLICAS=3`
- **WHEN** quorum is derived
- **THEN** the quorum equals 2

### Requirement: Password derivation

The system SHALL derive operator passwords using the same SHA-256 rule as `scripts/init.sh`: `sha256(cluster_id:username)`.

#### Scenario: op-replica password
- **GIVEN** `REDIS_CLUSTER_ID=redis-demo`
- **WHEN** the script derives the password for user `op-replica`
- **THEN** the result matches `printf '%s' "redis-demo:op-replica" | sha256sum | awk '{print $1}'`

