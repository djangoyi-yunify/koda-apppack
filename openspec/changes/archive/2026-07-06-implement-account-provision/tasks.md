## 1. Extend lifecycle.sh dispatcher

- [x] 1.1 Source `scripts/actions/account-provision.sh` in `scripts/lifecycle.sh`
- [x] 1.2 Add `accountProvision)` branch to the `case "$ACTION"` dispatch
- [x] 1.3 Pass `$PARAMS` to the `accountProvision` function

## 2. Implement account-provision action

- [x] 2.1 Create `scripts/actions/account-provision.sh` with no shebang and no top-level execution code
- [x] 2.2 Define `accountProvision()` that parses JSON input from `$1`
- [x] 2.3 Validate required fields `name` and `statement`; validate `password` for non-delete operations
- [x] 2.4 Validate `statement` does not start with `ACL ` and does not contain `;` or newlines
- [x] 2.5 Implement default ACL rules: `~* &* +@all` for `default` user, `~* +@read +@write +@connection` for others
- [x] 2.6 Implement create/update path: `ACL SETUSER <name> on ><password> <rules>` for both `redis-server` and `redis-sentinel`
- [x] 2.7 Implement delete path: `ACL DELUSER <name>` when `statement == "delete"` for both components
- [x] 2.8 Call `ACL SAVE` after successful `ACL SETUSER` or `ACL DELUSER`
- [x] 2.9 Select `REDIS_PORT` + `op-replica` for `redis-server`, `SENTINEL_PORT` + `op-sentinel` for `redis-sentinel`
- [x] 2.10 Use `derive_password` and `redis_cli_exec` helpers with the selected operator user

## 3. Testing and Validation

- [x] 3.1 Run shellcheck or bash syntax validation on modified scripts
- [x] 3.2 Test JSON parsing and validation paths with malformed input
- [x] 3.3 Test create/update path for `redis-server` and `redis-sentinel` with explicit and default ACL rules
- [x] 3.4 Test delete path for `redis-server` and `redis-sentinel`
- [x] 3.5 Verify component type selects correct port and operator user
- [x] 3.6 Test failure JSON output for missing required fields and invalid statements
- [x] 3.7 Run `openspec validate --specs` and ensure `redis-account-provision` is valid

## 4. Documentation

- [x] 4.1 Update `docs/design/redis-lifecycle-design.md` with `accountProvision` design details
- [x] 4.2 Review final diff for unintended changes
