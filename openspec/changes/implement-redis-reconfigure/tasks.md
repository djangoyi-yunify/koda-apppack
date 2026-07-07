## 1. Implement reconfigure action script

- [ ] 1.1 Create `scripts/actions/reconfigure.sh` with function definition and shebang comment
- [ ] 1.2 Add extensible Redis parameter defaults table to `reconfigure.sh`
- [ ] 1.3 Implement `reconfigure()` function with test-friendly signature reading `KODA_CONFIG_CHANGED_PARAMETERS`
- [ ] 1.4 Implement component type branch (`redis-server` vs `redis-sentinel`) for port and operator user selection
- [ ] 1.5 Implement JSON parsing with `jq`, failing gracefully when `jq` is missing
- [ ] 1.6 Implement added/updated parameter handling via `CONFIG SET`
- [ ] 1.7 Implement removed parameter handling via `CONFIG SET <default>` using defaults table
- [ ] 1.8 Implement `CONFIG REWRITE` call for `redis-server` after successful parameter application
- [ ] 1.9 Implement rejection of `sentinel.*` parameters
- [ ] 1.10 Implement strict failure on `CONFIG SET` errors and missing required environment variables

## 2. Update lifecycle dispatcher

- [ ] 2.1 Verify `scripts/lifecycle.sh` already sources `scripts/actions/reconfigure.sh`
- [ ] 2.2 Verify `scripts/lifecycle.sh` already dispatches `reconfigure` action to `reconfigure` function

## 3. Update helper if needed

- [ ] 3.1 Evaluate if `scripts/helper.sh` needs new shared utilities for `reconfigure`
- [ ] 3.2 Add any required shared helpers (e.g., config value validation)

## 4. Update design documentation

- [ ] 4.1 Update `docs/design/redis-lifecycle-design.md` to include `reconfigure` design section
- [ ] 4.2 Document koda-agent injected environment variables used by `reconfigure`
- [ ] 4.3 Document defaults table and removed parameter handling

## 5. Add tests

- [ ] 5.1 Create unit test mocking `redis-cli` to verify `CONFIG SET` calls for added/updated parameters
- [ ] 5.2 Create unit test verifying removed parameters use defaults table
- [ ] 5.3 Create unit test verifying `sentinel.*` parameters are rejected
- [ ] 5.4 Create unit test verifying `CONFIG REWRITE` is called for `redis-server`
- [ ] 5.5 Create e2e test verifying `reconfigure` updates running Redis and persists via `CONFIG REWRITE`
- [ ] 5.6 Run `bash -n` syntax check on `scripts/actions/reconfigure.sh`

## 6. Final verification

- [ ] 6.1 Run existing e2e tests to ensure no regression
- [ ] 6.2 Review `docs/design/redis-lifecycle-design.md` for consistency with implementation
