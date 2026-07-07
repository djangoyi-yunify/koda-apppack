## 1. Update research and rules

- [x] 1.1 Update `docs/research/redis-config-persistence-analysis.md` with Redis/Sentinel runtime config command differences
- [x] 1.2 Update `agent-rules/testing.md` with E2E scope requirements

## 2. Update OpenSpec artifacts

- [x] 2.1 Update `proposal.md` to scope reconfigure to `redis-server` only
- [x] 2.2 Update `specs/redis-reconfigure/spec.md` to remove redis-sentinel scenarios and `sentinel.*` rejection
- [x] 2.3 Update `design.md` to document redis-server-only support and Sentinel command-path difference
- [x] 2.4 Update `tasks.md` to reflect revised scope

## 3. Implement reconfigure action script

- [x] 3.1 Restrict `reconfigure()` to `redis-server`; fail for other component types
- [x] 3.2 Remove `sentinel.*` parameter rejection
- [x] 3.3 Keep JSON parsing with `jq`, failing gracefully when `jq` is missing
- [x] 3.4 Keep added/updated parameter handling via `CONFIG SET`
- [x] 3.5 Keep removed parameter handling via `CONFIG SET <default>` using defaults table
- [x] 3.6 Keep `CONFIG REWRITE` call after successful parameter application
- [x] 3.7 Keep strict failure on `CONFIG SET` errors and missing required environment variables

## 4. Update tests

- [x] 4.1 Update unit tests to reflect redis-server-only scope
- [x] 4.2 Remove sentinel-related unit test cases
- [x] 4.3 Move e2e test out of `redis-config-persistence` suite into standalone `tests/e2e/redis-reconfigure/`
- [x] 4.4 Remove task-04 from `tests/e2e/redis-config-persistence/run-all.sh`
- [x] 4.5 Run `bash -n` syntax check on `scripts/actions/reconfigure.sh`

## 5. Final verification

- [x] 5.1 Run unit tests
- [x] 5.2 Run standalone reconfigure e2e test
- [x] 5.3 Run existing `redis-config-persistence` e2e suite to ensure no regression
