## Context

`scripts/actions/account-provision.sh` 当前从 `$2` 读取 JSON 参数，期望调用方传入 `name`、`password`、`statement`。然而 Koda 执行 `accountProvision` 动作时，通过 koda-agent 将参数作为环境变量注入：`KODA_ACCOUNT_NAME`、`KODA_ACCOUNT_PASSWORD`、`KODA_ACCOUNT_STATEMENT`。这导致当前实现无法与真实 Koda 运行时的调用方式匹配。

本次变更旨在修正这一契约不匹配，使脚本正确读取 koda-agent 注入的环境变量，同时保留本地测试的便利性。

## Goals / Non-Goals

**Goals：**
- 修改 `accountProvision` 函数，从 koda-agent 注入的环境变量读取输入。
- 保留可选的手动 JSON 参数签名，便于本地单元测试。
- 更新 `redis-account-provision` spec 的输入契约。
- 更新 `docs/design/redis-lifecycle-design.md` 中关于 `accountProvision` 输入方式的描述。
- 更新相关测试以匹配新的输入方式。

**Non-Goals：**
- 不改变 `accountProvision` 的核心业务逻辑（ACL SETUSER / DELUSER、ACL SAVE）。
- 不修改 `lifecycle.sh` 的分发逻辑。
- 不修改 `scripts/helper.sh` 的共享函数。

## Decisions

### 1. 输入源：koda-agent 环境变量

**选择：** `accountProvision` 主输入来自 `KODA_ACCOUNT_NAME`、`KODA_ACCOUNT_PASSWORD`、`KODA_ACCOUNT_STATEMENT` 环境变量。

**理由：**
- 与 Koda `internal/controller/core/component/account_provision.go` 的实际行为一致。
- koda-agent 将 `ActionRequest.Parameters` 以环境变量形式注入 exec action。

**替代方案：** 继续要求调用方把 JSON 作为 `$2`。rejected，因为与 Koda 真实调用方式不符。

### 2. 保留测试友好型签名

**选择：** 函数签名支持可选的 JSON 参数；无参时读取环境变量。

**理由：**
- 便于本地运行和单元测试，无需设置多个环境变量。
- 与 `reconfigure` 的测试签名策略保持一致。

**实现形式：**

```bash
accountProvision() {
  local params_json="${1:-}"
  if [[ -n "$params_json" ]]; then
    # parse from JSON for manual testing
  else
    # read from KODA_ACCOUNT_* env vars
  fi
}
```

### 3. 移除 JSON 辅助函数或保留内部使用

**选择：** 保留 `_json_get_string` 用于手动测试路径；主路径不再依赖它。

**理由：**
- 避免重复实现 JSON 解析。
- 手动测试路径仍需要解析 JSON。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| 测试需要更新 | 同步修改所有调用 `accountProvision` 的测试用例 |
| 同时存在两种输入路径增加复杂度 | 主路径清晰明确；测试路径独立且可选 |
| 外部文档与旧 spec 不一致 | 同步更新 spec 和设计文档 |

## Migration Plan

1. 修改 `scripts/actions/account-provision.sh` 读取环境变量。
2. 更新 `openspec/specs/redis-account-provision/spec.md` 输入契约。
3. 更新 `docs/design/redis-lifecycle-design.md`。
4. 更新测试并运行回归测试。

## Open Questions

- 无。
