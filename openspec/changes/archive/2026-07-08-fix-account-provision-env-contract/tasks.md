## 1. Update account-provision.sh input handling

- [x] 1.1 Modify `accountProvision()` to read `KODA_ACCOUNT_NAME`, `KODA_ACCOUNT_PASSWORD`, `KODA_ACCOUNT_STATEMENT` from environment variables
- [x] 1.2 Retain optional JSON argument path for manual testing
- [x] 1.3 Update missing-field validation to check environment variables (and JSON fields in test path)
- [x] 1.4 Run `bash -n` syntax check on `scripts/actions/account-provision.sh`

## 2. Update lifecycle design documentation

- [x] 2.1 Update `docs/design/redis-lifecycle-design.md` section 5 to describe environment variable input for `accountProvision`
- [x] 2.2 Document koda-agent injected variables used by `accountProvision`

## 3. Update OpenSpec spec

- [x] 3.1 Verify `openspec/specs/redis-account-provision/spec.md` is updated to reflect environment variable contract
- [x] 3.2 Ensure delta spec in change directory is consistent with main spec

## 4. Update tests

- [x] 4.1 Update unit tests to set `KODA_ACCOUNT_*` environment variables instead of passing JSON
- [x] 4.2 Add a test case for the optional JSON argument path
- [x] 4.3 Add a test case verifying failure when required environment variables are missing
- [x] 4.4 Run all account-provision tests and ensure they pass

## 5. Final verification

- [x] 5.1 Run full lifecycle script syntax checks
- [x] 5.2 Run existing e2e tests to ensure no regression
- [x] 5.3 Review `docs/design/redis-lifecycle-design.md` for consistency
