## 1. Scaffold lifecycle.sh

- [x] 1.1 Create `scripts/lifecycle.sh` with shebang `#!/usr/bin/env bash` and `set -euo pipefail`
- [x] 1.2 Add action dispatch based on `$1` with `postProvision` handler and fallback for unsupported actions
- [x] 1.3 Implement `fail_json` helper that outputs `{status:"failure",message,error}` and exits non-zero
- [x] 1.4 Implement `success_json` helper that outputs `{status:"success",message,error:""}` and exits zero
- [x] 1.5 Implement `derive_password` helper matching `scripts/init.sh` exactly

## 2. Implement redis-server postProvision

- [x] 2.1 Validate required environment variables for `redis-server` component
- [x] 2.2 Derive ordinal from `HOSTNAME`
- [x] 2.3 Skip `REPLICAOF` when ordinal equals 0 and output success JSON
- [x] 2.4 Construct master FQDN using `KODA_HEADLESS_SERVICE`
- [x] 2.5 Execute `REPLICAOF <master-fqdn> <redis-port>` via redis-cli using `op-replica` credentials
- [x] 2.6 Handle redis-cli errors and output failure JSON

## 3. Implement redis-sentinel postProvision

- [x] 3.1 Validate required environment variables for `redis-sentinel` component including `KODA_SENTINEL_REPLICAS`
- [x] 3.2 Derive quorum from `KODA_SENTINEL_REPLICAS` using integer division `(replicas / 2) + 1`
- [x] 3.3 Construct master name and master FQDN
- [x] 3.4 Query existing monitor via `SENTINEL MASTER <master-name>` using `op-sentinel` credentials
- [x] 3.5 Execute `SENTINEL MONITOR` only when master is not yet monitored, treating already-monitored errors as success
- [x] 3.6 Execute `SENTINEL SET auth-user op-replica` and `SENTINEL SET auth-pass <derived-pass>`
- [x] 3.7 Output success JSON

## 4. Declare postProvision in ComponentDefinition

> **Cancelled**: `charts/redis-pack/` 目录不存在，ComponentDefinition 模板尚未创建。该工作推迟到后续 Chart 变更。

## 5. Testing and Validation

- [x] 5.1 Run shellcheck or bash syntax validation on `scripts/lifecycle.sh`
- [x] 5.2 Test `fail_json` and `success_json` output manually
- [x] 5.3 Test password derivation matches `scripts/init.sh` output

## 6. Documentation and Cleanup

- [x] 6.1 Update `docs/design/redis-lifecycle-design.md` if implementation diverges from design
- [x] 6.2 Ensure `AGENT.md` references `docs/design/redis-lifecycle-design.md`
- [x] 6.3 Review final diff for unintended changes
