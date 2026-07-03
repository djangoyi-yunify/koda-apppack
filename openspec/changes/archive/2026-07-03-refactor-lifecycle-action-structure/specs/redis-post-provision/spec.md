## MODIFIED Requirements

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
