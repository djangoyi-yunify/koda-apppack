# redis-account-provision Specification (Delta)

## MODIFIED Requirements

### Requirement: accountProvision input contract

The system SHALL read action parameters from koda-agent-injected environment variables. The required variables are `KODA_ACCOUNT_NAME`, `KODA_ACCOUNT_PASSWORD` (except for delete operations), and `KODA_ACCOUNT_STATEMENT`. The function SHALL also accept an optional JSON string argument for manual testing, defaulting to the environment variable values.

#### Scenario: accountProvision reads from environment variables

- **GIVEN** `KODA_ACCOUNT_NAME=app`, `KODA_ACCOUNT_PASSWORD=secret`, `KODA_ACCOUNT_STATEMENT="~* +@all"`
- **WHEN** `accountProvision` is invoked without arguments
- **THEN** the script proceeds to execute the ACL command

#### Scenario: accountProvision is invoked with valid JSON parameters for testing

- **GIVEN** `name=app`, `password=secret`, `statement="~* +@all"`
- **WHEN** `accountProvision` is invoked with the JSON string `'{"name":"app","password":"secret","statement":"~* +@all"}'`
- **THEN** the script proceeds to execute the ACL command

#### Scenario: accountProvision is invoked with missing name

- **GIVEN** `KODA_ACCOUNT_NAME` is unset or empty
- **WHEN** `accountProvision` is invoked
- **THEN** the script outputs a failure JSON and exits non-zero

#### Scenario: accountProvision is invoked with missing password for non-delete operation

- **GIVEN** `KODA_ACCOUNT_STATEMENT` is not `"delete"` and `KODA_ACCOUNT_PASSWORD` is unset or empty
- **WHEN** `accountProvision` is invoked
- **THEN** the script outputs a failure JSON and exits non-zero

#### Scenario: accountProvision is invoked with missing statement

- **GIVEN** `KODA_ACCOUNT_STATEMENT` is unset or empty
- **WHEN** `accountProvision` is invoked
- **THEN** the script outputs a failure JSON and exits non-zero

## REMOVED Requirements

### Requirement: accountProvision accepts JSON parameters in $2

**Reason**: Koda injects account provision parameters as environment variables (`KODA_ACCOUNT_NAME`, `KODA_ACCOUNT_PASSWORD`, `KODA_ACCOUNT_STATEMENT`) rather than as a JSON string in `$2`. The input contract is updated to match the actual koda-agent calling behavior.

**Migration**: Callers should set the `KODA_ACCOUNT_*` environment variables before invoking `accountProvision`. For local testing, an optional JSON argument is still supported.
