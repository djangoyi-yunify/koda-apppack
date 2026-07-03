## Why

Redis AppPack 第一阶段目标拓扑是 replication + Sentinel。当前仓库已具备 `scripts/init.sh` 完成初始化，但缺少组件就绪后的 `postProvision` 生命周期动作。没有该动作，Sentinel 无法自动开始监控 Redis primary，replica 也无法在运行时被正确指向 primary。本次变更引入统一的生命周期脚本入口并实现 `postProvision`，使 Redis 组件在 Koda 平台上完成启动后的关键拓扑初始化。

## What Changes

- 新增 `scripts/lifecycle.sh`：统一的生命周期动作脚本入口，按 `$1` 动作名分发；
- 在 `lifecycle.sh` 中实现 `postProvision` 分支：
  - `redis-server` 组件：在 ordinal ≠ 0 的实例上执行 `REPLICAOF`；
  - `redis-sentinel` 组件：执行 `SENTINEL MONITOR`、配置 quorum、`auth-user`、`auth-pass`；
- 其余生命周期动作（`roleProbe`、`availableProbe`、`switchover`、`memberJoin`、`memberLeave`、`reconfigure`）在本次变更中不实现，但脚本结构预留扩展点。

## Out of Scope

- `postProvision` 在 `ComponentDefinition` 中的声明与 Chart 模板渲染：仓库目前尚无 `charts/redis-pack/`，该工作留到后续变更。

## Capabilities

### New Capabilities

- `redis-post-provision`：定义 Redis AppPack 中 `postProvision` 生命周期动作的接口、行为与幂等性保证。

### Modified Capabilities

- 无现有 spec 需求变更。

## Impact

- 新增脚本文件：`scripts/lifecycle.sh`；
- 依赖 `scripts/init.sh` 已创建的 operator 账号与 ACL 规则；
- 不修改现有 `scripts/init.sh` 行为；
- `ComponentDefinition` 中声明 `lifecycle.actions.postProvision` 的工作推迟到 Chart 结构创建之后。
