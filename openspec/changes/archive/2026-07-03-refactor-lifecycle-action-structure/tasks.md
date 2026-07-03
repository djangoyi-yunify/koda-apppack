## 1. Create helper.sh

- [x] 1.1 Create `scripts/helper.sh` with shebang `#!/usr/bin/env bash` (no `set -euo pipefail` since it is sourced)
- [x] 1.2 Move `json_escape`, `fail_json`, `success_json` from `lifecycle.sh` to `helper.sh`
- [x] 1.3 Move `derive_password`, `require_env`, `derive_ordinal` from `lifecycle.sh` to `helper.sh`
- [x] 1.4 Move `redis_cli_exec` and `redis_cli_failed` from `lifecycle.sh` to `helper.sh`

## 2. Create actions directory and post-provision action

- [x] 2.1 Create `scripts/actions/` directory
- [x] 2.2 Create `scripts/actions/post-provision.sh` defining a `postProvision` function
- [x] 2.3 Move redis-server and redis-sentinel postProvision logic into `postProvision` function
- [x] 2.4 Ensure `post-provision.sh` has no top-level execution code outside function definitions
- [x] 2.5 Ensure `post-provision.sh` has no shebang and no execute permission

## 3. Create placeholder action scripts

- [x] 3.1 Create `scripts/actions/role-probe.sh` with a placeholder function returning not-implemented
- [x] 3.2 Create `scripts/actions/available-probe.sh` with a placeholder function returning not-implemented
- [x] 3.3 Create `scripts/actions/switchover.sh` with a placeholder function returning not-implemented
- [x] 3.4 Create `scripts/actions/member-join.sh` with a placeholder function returning not-implemented
- [x] 3.5 Create `scripts/actions/member-leave.sh` with a placeholder function returning not-implemented
- [x] 3.6 Create `scripts/actions/reconfigure.sh` with a placeholder function returning not-implemented

## 4. Refactor lifecycle.sh into dispatcher

- [x] 4.1 Replace existing `lifecycle.sh` body with `source scripts/helper.sh`
- [x] 4.2 Add static list of `source scripts/actions/*.sh` for all action scripts
- [x] 4.3 Add `case "$ACTION"` dispatch calling functions by name (`postProvision`, `roleProbe`, etc.)
- [x] 4.4 Handle empty `$1` and unknown actions with `fail_json`
- [x] 4.5 Remove old inline helper functions and postProvision logic after confirming they are moved

## 5. Update documentation

- [x] 5.1 Update `docs/design/redis-lifecycle-design.md` section 2 to describe dispatcher + helper + action files structure
- [x] 5.2 Update `docs/design/redis-lifecycle-design.md` section 3 to show function dispatch instead of inline case logic
- [x] 5.3 Add convention note: action scripts define functions only and are not standalone entrypoints

## 6. Testing and validation

- [x] 6.1 Run `bash -n` syntax check on `scripts/lifecycle.sh`, `scripts/helper.sh`, and all action scripts
- [x] 6.2 Test successful `postProvision` for redis-server ordinal 0
- [x] 6.3 Test `postProvision` failure paths still output JSON and exit non-zero
- [x] 6.4 Test unknown action returns failure JSON
- [x] 6.5 Verify `postProvision` business output matches pre-refactor behavior
- [x] 6.6 Run `openspec validate --specs` and ensure `redis-post-provision` is valid
