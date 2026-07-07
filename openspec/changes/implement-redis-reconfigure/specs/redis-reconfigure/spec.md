# redis-reconfigure Specification

## Purpose

Define the `reconfigure` lifecycle action for Redis AppPack, including the JSON input contract from koda-agent, parameter handling for `redis-server` and `redis-sentinel` components, default value table for removed parameters, and output format.

## ADDED Requirements

### Requirement: Unified lifecycle script entrypoint supports reconfigure

The system SHALL extend the unified lifecycle script entrypoint at `scripts/lifecycle.sh` to dispatch the `reconfigure` action to the `reconfigure` function defined in `scripts/actions/reconfigure.sh`.

#### Scenario: Script receives reconfigure action name

- **WHEN** Koda invokes `/scripts/lifecycle.sh reconfigure '{}'`
- **THEN** `lifecycle.sh` calls the `reconfigure` function

### Requirement: reconfigure action function library

The system SHALL provide an action function library at `scripts/actions/reconfigure.sh` that defines a `reconfigure` function and contains no top-level execution code outside function definitions.

#### Scenario: reconfigure action is defined in its own file

- **WHEN** inspecting `scripts/actions/reconfigure.sh`
- **THEN** it defines a `reconfigure` function and contains no top-level execution code outside function definitions

#### Scenario: Action script is not standalone

- **WHEN** attempting to execute `scripts/actions/reconfigure.sh` directly
- **THEN** it does not run as an independent entrypoint

### Requirement: reconfigure input contract

The system SHALL read action parameters from koda-agent-injected environment variables. The canonical input SHALL be the JSON array in `KODA_CONFIG_CHANGED_PARAMETERS`. The function SHALL also accept an optional JSON argument for manual testing, defaulting to the environment variable value.

#### Scenario: reconfigure reads from KODA_CONFIG_CHANGED_PARAMETERS

- **GIVEN** `KODA_CONFIG_CHANGED_PARAMETERS='[{"key":"maxmemory","newValue":"536870912"}]'`
- **WHEN** `reconfigure` is invoked without arguments
- **THEN** the script applies the changed parameter

#### Scenario: reconfigure accepts manual JSON argument

- **GIVEN** `reconfigure` is invoked as `reconfigure '[{"key":"maxmemory","newValue":"536870912"}]'`
- **WHEN** the function executes
- **THEN** it applies the changed parameter from the argument

### Requirement: reconfigure parses JSON with jq

The system SHALL use `jq` to parse `KODA_CONFIG_CHANGED_PARAMETERS`. If `jq` is not available, the system SHALL output a failure JSON and exit non-zero.

#### Scenario: jq is available

- **GIVEN** `jq` is installed in the execution environment
- **WHEN** `reconfigure` is invoked with valid changed parameters
- **THEN** the parameters are parsed successfully

#### Scenario: jq is missing

- **GIVEN** `jq` is not installed in the execution environment
- **WHEN** `reconfigure` is invoked
- **THEN** the script outputs `{"status":"failure","message":"...","error":"..."}` and exits non-zero

### Requirement: reconfigure output contract

The system SHALL output a JSON object to stdout with exactly the fields `status`, `message`, and `error`.

#### Scenario: Action succeeds

- **WHEN** the `reconfigure` handler completes successfully
- **THEN** stdout contains `{"status":"success","message":"...","error":""}`

#### Scenario: Action fails

- **WHEN** the `reconfigure` handler encounters an error
- **THEN** stdout contains `{"status":"failure","message":"...","error":"..."}` before the script exits non-zero

### Requirement: reconfigure selects port and operator user based on component type

The system SHALL select the target port and operator username based on `KODA_COMPONENT_TYPE`. For `redis-server`, the system SHALL use `REDIS_PORT` and the `op-replica` operator user. For `redis-sentinel`, the system SHALL use `SENTINEL_PORT` and the `op-sentinel` operator user.

#### Scenario: redis-server component reconfigure

- **GIVEN** `KODA_COMPONENT_TYPE=redis-server`
- **WHEN** `reconfigure` executes a redis-cli command
- **THEN** the command targets `127.0.0.1:REDIS_PORT` using the `op-replica` user

#### Scenario: redis-sentinel component reconfigure

- **GIVEN** `KODA_COMPONENT_TYPE=redis-sentinel`
- **WHEN** `reconfigure` executes a redis-cli command
- **THEN** the command targets `127.0.0.1:SENTINEL_PORT` using the `op-sentinel` user

### Requirement: reconfigure applies added and updated parameters

For each changed parameter with a non-null `newValue`, the system SHALL execute `CONFIG SET <key> <newValue>` on the local Redis or Sentinel instance.

#### Scenario: Update maxmemory on redis-server

- **GIVEN** `KODA_COMPONENT_TYPE=redis-server` and `KODA_CONFIG_CHANGED_PARAMETERS='[{"key":"maxmemory","newValue":"536870912"}]'`
- **WHEN** `reconfigure` is invoked
- **THEN** the script executes `CONFIG SET maxmemory 536870912`

#### Scenario: Update loglevel on redis-sentinel

- **GIVEN** `KODA_COMPONENT_TYPE=redis-sentinel` and `KODA_CONFIG_CHANGED_PARAMETERS='[{"key":"loglevel","newValue":"debug"}]'`
- **WHEN** `reconfigure` is invoked
- **THEN** the script executes `CONFIG SET loglevel debug`

### Requirement: reconfigure allows values containing spaces

The system SHALL support parameter values that contain whitespace, such as multi-token Redis configuration values.

#### Scenario: Update client-output-buffer-limit

- **GIVEN** `KODA_CONFIG_CHANGED_PARAMETERS='[{"key":"client-output-buffer-limit","newValue":"normal 0 0 0"}]'`
- **WHEN** `reconfigure` is invoked
- **THEN** the script executes `CONFIG SET client-output-buffer-limit "normal 0 0 0"`

### Requirement: reconfigure rejects unsupported dynamic parameters

If Redis returns an error for a `CONFIG SET` command, the system SHALL output a failure JSON and exit non-zero.

#### Scenario: Set an immutable parameter

- **GIVEN** `KODA_CONFIG_CHANGED_PARAMETERS='[{"key":"bind","newValue":"127.0.0.1"}]'` and Redis rejects the change
- **WHEN** `reconfigure` is invoked
- **THEN** the script outputs a failure JSON and exits non-zero

### Requirement: reconfigure rejects Sentinel master parameters

The system SHALL reject parameters whose key starts with `sentinel.`, because Sentinel master-specific parameters are out of scope for this action.

#### Scenario: Sentinel master parameter is passed

- **GIVEN** `KODA_COMPONENT_TYPE=redis-sentinel` and `KODA_CONFIG_CHANGED_PARAMETERS='[{"key":"sentinel.down-after-milliseconds","newValue":"3000"}]'`
- **WHEN** `reconfigure` is invoked
- **THEN** the script outputs a failure JSON indicating the parameter is not supported

### Requirement: reconfigure handles removed parameters with default values

For each changed parameter with a null `newValue`, the system SHALL look up the default value in the Redis parameter defaults table and execute `CONFIG SET <key> <defaultValue>`.

#### Scenario: Remove maxmemory

- **GIVEN** `KODA_CONFIG_CHANGED_PARAMETERS='[{"key":"maxmemory","oldValue":"536870912","newValue":null}]'` and the defaults table defines `maxmemory=0`
- **WHEN** `reconfigure` is invoked
- **THEN** the script executes `CONFIG SET maxmemory 0`

### Requirement: reconfigure fails on unknown removed parameters

If a removed parameter is not present in the defaults table, the system SHALL output a failure JSON and exit non-zero.

#### Scenario: Removed parameter has no known default

- **GIVEN** `KODA_CONFIG_CHANGED_PARAMETERS='[{"key":"unknown-param","oldValue":"x","newValue":null}]'` and the defaults table has no entry for `unknown-param`
- **WHEN** `reconfigure` is invoked
- **THEN** the script outputs a failure JSON and exits non-zero

### Requirement: reconfigure persists changes on redis-server

After all changed parameters are successfully applied, the system SHALL execute `CONFIG REWRITE` on `redis-server` to persist the configuration to `/data/redis-runtime.conf`.

#### Scenario: Persist successful update

- **GIVEN** `KODA_COMPONENT_TYPE=redis-server` and all `CONFIG SET` commands succeed
- **WHEN** `reconfigure` completes
- **THEN** the script executes `CONFIG REWRITE`

#### Scenario: CONFIG REWRITE fails

- **GIVEN** `KODA_COMPONENT_TYPE=redis-server` and `CONFIG REWRITE` returns an error
- **WHEN** `reconfigure` is invoked
- **THEN** the script outputs a failure JSON and exits non-zero

### Requirement: reconfigure is idempotent

The system SHALL allow `reconfigure` to be invoked multiple times with the same parameters without adverse effects.

#### Scenario: Re-run reconfigure with identical parameters

- **GIVEN** `maxmemory` is already set to `536870912`
- **WHEN** `reconfigure` is invoked with the same parameter
- **THEN** the script succeeds and the configuration remains `536870912`

### Requirement: reconfigure documents koda-agent calling contract

The system SHALL update `docs/design/redis-lifecycle-design.md` to document the koda-agent-injected environment variables that `reconfigure` consumes.

#### Scenario: Design doc references KODA_CONFIG_CHANGED_PARAMETERS

- **WHEN** inspecting `docs/design/redis-lifecycle-design.md`
- **THEN** it contains a section describing `KODA_CONFIG_CHANGED_PARAMETERS` and other koda-agent injected variables used by `reconfigure`
