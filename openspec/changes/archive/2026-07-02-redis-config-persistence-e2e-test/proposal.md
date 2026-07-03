## Why

`docs/research/redis-config-persistence-analysis.md` 建议在容器环境中使用“主配置文件 + `include` 只读模板”的方式解决 Redis/Sentinel 配置文件回写与持久化问题。该机制的正确性直接影响 Koda  Redis AppPack 在 Pod 重启、故障转移后能否恢复正确角色与拓扑认知。我们需要在真实 Redis 7.2.14 行为上做最小化 e2e 验证，确保文档建议成立，再将其落地到生命周期脚本与 Chart 模板中。

## What Changes

- 在 `tests/e2e/redis-config-persistence/` 下新增一组 Bash e2e 测试脚本。
- 验证 Redis `include` 隔离性：`CONFIG REWRITE` 只修改可写的主配置文件，不污染只读模板。
- 验证 `replicaof` / `masterauth` 在主配置文件中的持久化与重启恢复。
- 验证 Sentinel 的 `requirepass`、`auth-pass` 生效，以及 `known-replica`、`config-epoch` 的自动回写与重启恢复。
- 测试脚本遵循 `agent-rules/testing.md` 的粒度要求：每个任务独立可运行，逐个执行，最后做完整回归测试。

## Capabilities

### New Capabilities

- `redis-config-persistence-e2e`: 使用本地 `redis-server` 验证 Redis 7.2.14 下 `include` + 持久化主配置文件的 e2e 行为。

### Modified Capabilities

- 无

## Impact

- 新增 `tests/e2e/redis-config-persistence/` 目录及脚本。
- 不影响 `charts/redis-pack/`、`scripts/`、`configs/` 等现有交付物。
- 依赖本地已安装的 Redis 7.2.14 二进制（`redis-server`、`redis-cli`、`redis-sentinel`）。
