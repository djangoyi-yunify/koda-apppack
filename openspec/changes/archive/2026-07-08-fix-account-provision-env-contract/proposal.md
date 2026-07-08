## Why

当前 `scripts/actions/account-provision.sh` 从 `$2` 读取 JSON 参数，但 Koda 实际调用 `accountProvision` 动作时，是通过 koda-agent 把参数注入为环境变量（`KODA_ACCOUNT_NAME`、`KODA_ACCOUNT_PASSWORD`、`KODA_ACCOUNT_STATEMENT`）。这导致实现与 Koda 真实调用契约不匹配，动作无法在实际平台中正确接收账号信息。

## What Changes

- 修改 `scripts/actions/account-provision.sh`，将输入来源从 `$2` JSON 改为 koda-agent 注入的环境变量。
- 保留可选的测试友好型签名，允许手动传入 JSON 参数用于本地验证。
- 更新 OpenSpec spec `redis-account-provision`，将输入契约从 JSON 参数改为环境变量注入。
- 更新 `docs/design/redis-lifecycle-design.md` 中关于 `accountProvision` 输入契约的描述。
- 更新现有测试以匹配新的环境变量输入方式。

## Capabilities

### New Capabilities

- 无。

### Modified Capabilities

- `redis-account-provision`: 输入契约从 `$2` JSON 参数改为 koda-agent 注入的 `KODA_ACCOUNT_NAME`、`KODA_ACCOUNT_PASSWORD`、`KODA_ACCOUNT_STATEMENT` 环境变量。

## Impact

- 修改文件：`scripts/actions/account-provision.sh`、`openspec/specs/redis-account-provision/spec.md`、`docs/design/redis-lifecycle-design.md`、相关测试文件。
- 行为变更：脚本不再要求调用方传入 JSON 参数，而是读取环境变量。
- 这是 **BREAKING** 变更，仅影响当前仓库内部实现与测试；外部 Koda 调用方式不变。
