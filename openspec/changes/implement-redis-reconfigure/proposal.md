## Why

Redis AppPack 当前已实现 `postProvision` 与 `accountProvision`，但 `reconfigure` 生命周期动作仍是占位实现，无法响应 Koda 的参数热更新。缺少该动作意味着用户通过 `ComponentParameter` 修改的配置无法在不重启 Pod 的情况下生效，降低了 Redis 的 Day-2 运维能力。

## What Changes

- 实现 `scripts/actions/reconfigure.sh` 中的 `reconfigure` 函数，支持 `redis-server` 与 `redis-sentinel` 组件。
- 通过 `KODA_CONFIG_CHANGED_PARAMETERS` 解析变更参数，使用 `jq` 处理 JSON。
- 对新增/更新参数执行 `CONFIG SET`，对 removed 参数执行 `CONFIG SET <default>`。
- 所有成功应用后调用 `CONFIG REWRITE`，保证运行中配置与持久化配置一致。
- 维护一份可扩展的 Redis 通用参数默认值表，用于 removed 参数恢复。
- 更新 `docs/design/redis-lifecycle-design.md`，补充 `reconfigure` 设计说明与 koda-agent 调用契约。
- 新增单元测试与 e2e 测试覆盖 `CONFIG SET` + `CONFIG REWRITE` 路径。

## Capabilities

### New Capabilities

- `redis-reconfigure`: 定义 Redis AppPack `reconfigure` 生命周期动作的输入契约、参数处理策略、组件分支、默认值表、输出格式与幂等性保证。

### Modified Capabilities

- 无。

## Impact

- 新增/修改文件：`scripts/actions/reconfigure.sh`、`scripts/helper.sh`（可能）、`docs/design/redis-lifecycle-design.md`、测试文件。
- 不修改 `scripts/init.sh`，保持现有 `include` 配置模型不变。
- 依赖 `jq` 存在于执行 reconfigure 的容器镜像中。
