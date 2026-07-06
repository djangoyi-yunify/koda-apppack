# redis-account-provision Specification

## Purpose

Define the `accountProvision` lifecycle action for Redis AppPack, including the JSON input contract, ACL rule handling, default permissions, supported component types (`redis-server` and `redis-sentinel`), idempotency, and output format.

## ADDED Requirements

### Requirement: Unified lifecycle script entrypoint supports accountProvision

The system SHALL extend the unified lifecycle script entrypoint at `scripts/lifecycle.sh` to dispatch the `accountProvision` action to the `accountProvision` function defined in `scripts/actions/account-provision.sh`.

#### Scenario: Script receives accountProvision action name

- **WHEN** Koda invokes `/scripts/lifecycle.sh accountProvision '<json-params>'`
- **THEN** `lifecycle.sh` calls the `accountProvision` function with the JSON parameters

#### Scenario: Script sources the account-provision action library

- **WHEN** inspecting `scripts/lifecycle.sh`
- **THEN** it sources `scripts/actions/account-provision.sh`

### Requirement: accountProvision action function library

The system SHALL provide an action function library at `scripts/actions/account-provision.sh` that defines an `accountProvision` function and contains no top-level execution code outside function definitions.

#### Scenario: accountProvision action is defined in its own file

- **WHEN** inspecting `scripts/actions/account-provision.sh`
- **THEN** it defines an `accountProvision` function and contains no top-level execution code outside function definitions

#### Scenario: Action script is not standalone

- **WHEN** attempting to execute `scripts/actions/account-provision.sh` directly
- **THEN** it does not run as an independent entrypoint

### Requirement: accountProvision input contract

The system SHALL accept action parameters as a JSON string in `$2`. The JSON object SHALL contain `name` and `password` as required string fields and `statement` as a required string field.

#### Scenario: accountProvision is invoked with valid JSON parameters

- **GIVEN** `name=app`, `password=secret`, `statement="~* +@all"`
- **WHEN** `accountProvision` is invoked
- **THEN** the script proceeds to execute the ACL command

#### Scenario: accountProvision is invoked with missing name

- **GIVEN** the JSON input lacks the `name` field
- **WHEN** `accountProvision` is invoked
- **THEN** the script outputs a failure JSON and exits non-zero

#### Scenario: accountProvision is invoked with missing password for non-delete operation

- **GIVEN** `statement` is not `"delete"` and the JSON input lacks the `password` field
- **WHEN** `accountProvision` is invoked
- **THEN** the script outputs a failure JSON and exits non-zero

#### Scenario: accountProvision is invoked with missing statement

- **GIVEN** the JSON input lacks the `statement` field
- **WHEN** `accountProvision` is invoked
- **THEN** the script outputs a failure JSON and exits non-zero

### Requirement: accountProvision output contract

The system SHALL output a JSON object to stdout with exactly the fields `status`, `message`, and `error`.

#### Scenario: Action succeeds

- **WHEN** the `accountProvision` handler completes successfully
- **THEN** stdout contains `{"status":"success","message":"...","error":""}`

#### Scenario: Action fails

- **WHEN** the `accountProvision` handler encounters an error
- **THEN** stdout contains `{"status":"failure","message":"...","error":"..."}` before the script exits non-zero

### Requirement: accountProvision validates statement values

The system SHALL validate the `statement` field to prevent accidental operations. The system SHALL reject an empty `statement`, a `statement` starting with `ACL ` for non-delete operations, and any `statement` containing `;` or newline characters.

#### Scenario: Statement starts with ACL prefix

- **GIVEN** `statement` is `"ACL SETUSER app >secret ~* +@all"`
- **WHEN** `accountProvision` is invoked
- **THEN** the script outputs a failure JSON indicating an invalid statement

#### Scenario: Statement contains semicolon

- **GIVEN** `statement` is `"~* +@all; FLUSHALL"`
- **WHEN** `accountProvision` is invoked
- **THEN** the script outputs a failure JSON indicating an invalid statement

### Requirement: accountProvision creates or updates users for supported components

For the `redis-server` and `redis-sentinel` components, when `statement` is not `"delete"`, the system SHALL execute `ACL SETUSER <name> on ><password> <statement>` followed by `ACL SAVE`.

#### Scenario: Create a user on redis-server with explicit ACL rules

- **GIVEN** `KODA_COMPONENT_TYPE=redis-server`, `name=app`, `password=secret`, `statement="~* +@read +@write +@connection"`
- **WHEN** `accountProvision` is invoked
- **THEN** the script executes `ACL SETUSER app on >secret ~* +@read +@write +@connection` via `redis-cli` on `REDIS_PORT` and then `ACL SAVE`

#### Scenario: Create a user on redis-sentinel with explicit ACL rules

- **GIVEN** `KODA_COMPONENT_TYPE=redis-sentinel`, `name=app`, `password=secret`, `statement="~* +@read +@write +@connection"`
- **WHEN** `accountProvision` is invoked
- **THEN** the script executes `ACL SETUSER app on >secret ~* +@read +@write +@connection` via `redis-cli` on `SENTINEL_PORT` and then `ACL SAVE`

#### Scenario: Create the default user with default rules

- **GIVEN** `KODA_COMPONENT_TYPE=redis-server`, `name=default`, `password=secret`, and `statement` is empty
- **WHEN** `accountProvision` is invoked
- **THEN** the script executes `ACL SETUSER default on >secret ~* &* +@all` and then `ACL SAVE`

#### Scenario: Create a non-default user with default rules

- **GIVEN** `KODA_COMPONENT_TYPE=redis-server`, `name=app`, `password=secret`, and `statement` is empty
- **WHEN** `accountProvision` is invoked
- **THEN** the script executes `ACL SETUSER app on >secret ~* +@read +@write +@connection` and then `ACL SAVE`

### Requirement: accountProvision deletes users for supported components

For the `redis-server` and `redis-sentinel` components, when `statement` equals `"delete"`, the system SHALL execute `ACL DELUSER <name>` followed by `ACL SAVE`.

#### Scenario: Delete an existing user on redis-server

- **GIVEN** `KODA_COMPONENT_TYPE=redis-server`, `name=app`, `statement="delete"`
- **WHEN** `accountProvision` is invoked
- **THEN** the script executes `ACL DELUSER app` and then `ACL SAVE`

#### Scenario: Delete an existing user on redis-sentinel

- **GIVEN** `KODA_COMPONENT_TYPE=redis-sentinel`, `name=app`, `statement="delete"`
- **WHEN** `accountProvision` is invoked
- **THEN** the script executes `ACL DELUSER app` and then `ACL SAVE`

### Requirement: accountProvision is idempotent

The system SHALL allow `accountProvision` to be invoked multiple times for the same user without adverse effects. `ACL SETUSER`, `ACL DELUSER`, and `ACL SAVE` are inherently idempotent or retry-safe.

#### Scenario: Create user is invoked again

- **GIVEN** user `app` already exists with the desired ACL rules
- **WHEN** `accountProvision` is invoked with the same parameters
- **THEN** the script succeeds and the user remains configured as expected

### Requirement: accountProvision persists ACL changes

The system SHALL call `ACL SAVE` after any successful `ACL SETUSER` or `ACL DELUSER` execution so that the ACL configuration is written to the external ACL file configured by `init.sh`.

#### Scenario: ACL SAVE is invoked after SETUSER

- **GIVEN** `accountProvision` successfully executes `ACL SETUSER`
- **THEN** the script executes `ACL SAVE` before returning success

### Requirement: accountProvision selects port and operator user based on component type

The system SHALL select the target port and operator username based on `KODA_COMPONENT_TYPE`. For `redis-server`, the system SHALL use `REDIS_PORT` and the `op-replica` operator user. For `redis-sentinel`, the system SHALL use `SENTINEL_PORT` and the `op-sentinel` operator user.

#### Scenario: redis-server component uses op-replica on REDIS_PORT

- **GIVEN** `KODA_COMPONENT_TYPE=redis-server`
- **WHEN** `accountProvision` executes a redis-cli command
- **THEN** the command targets `127.0.0.1:REDIS_PORT` using the `op-replica` user

#### Scenario: redis-sentinel component uses op-sentinel on SENTINEL_PORT

- **GIVEN** `KODA_COMPONENT_TYPE=redis-sentinel`
- **WHEN** `accountProvision` executes a redis-cli command
- **THEN** the command targets `127.0.0.1:SENTINEL_PORT` using the `op-sentinel` user

### Requirement: accountProvision uses operator credentials

The system SHALL connect to the local Redis or Sentinel instance using the operator user appropriate for the component type and the password derived from `REDIS_CLUSTER_ID` and the username.

#### Scenario: redis-server operator password derivation

- **GIVEN** `REDIS_CLUSTER_ID=redis-demo`, `KODA_COMPONENT_TYPE=redis-server`, and the operator username is `op-replica`
- **WHEN** the script derives the operator password
- **THEN** the result matches `printf '%s' "redis-demo:op-replica" | sha256sum | awk '{print $1}'`

#### Scenario: redis-sentinel operator password derivation

- **GIVEN** `REDIS_CLUSTER_ID=redis-demo`, `KODA_COMPONENT_TYPE=redis-sentinel`, and the operator username is `op-sentinel`
- **WHEN** the script derives the operator password
- **THEN** the result matches `printf '%s' "redis-demo:op-sentinel" | sha256sum | awk '{print $1}'`

### Requirement: accountProvision error paths produce JSON

The system SHALL ensure that any error path outputs a valid failure JSON to stdout before exiting with a non-zero code.

#### Scenario: Redis command returns an error

- **WHEN** a redis-cli command returns an error response
- **THEN** the script outputs a failure JSON and exits non-zero

#### Scenario: Missing required environment variable

- **WHEN** `KODA_COMPONENT_TYPE` or `REDIS_CLUSTER_ID` is missing
- **THEN** the script outputs a failure JSON and exits non-zero
