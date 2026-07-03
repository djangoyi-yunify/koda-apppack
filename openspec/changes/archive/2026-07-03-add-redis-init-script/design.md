## Context

`docs/design/redis-init-script-design.md` 已详细描述 Redis 初始化脚本的需求与方案。本变更将其实现为 `scripts/init.sh`。

当前 `scripts/` 目录为空，Chart 模板中 initContainers 缺少可执行的初始化入口。

## Goals / Non-Goals

**Goals:**

- 实现一个平台中立的 Bash 初始化脚本 `scripts/init.sh`。
- 支持 `server` 与 `sentinel` 两种组件初始化。
- 生成主配置文件、ACL 文件，创建必要目录。
- 保证幂等性，Pod 重启后不破坏已持久化状态。

**Non-Goals:**

- 不实现 Koda 特定的 CRD 读取或状态查询。
- 不做主从角色判定、`replicaof` 下发。
- 不写 `sentinel monitor` 与 quorum 配置。
- 不创建业务用户（由后续 `accountProvision` 处理）。

## Decisions

### 使用单一脚本通过参数区分组件

- **原因**：server 与 sentinel 的初始化流程高度相似（目录创建、ACL 初始化），单一脚本便于维护。
- **替代方案**：拆分为 `init-redis-server.sh` 与 `init-redis-sentinel.sh`，但公共逻辑会重复。

### 密码从 `REDIS_CLUSTER_ID` 派生

- **原因**：`REDIS_CLUSTER_ID` 来自 Koda CR 名称或 UUID，在整个 CR 生命周期中保持不变且易于注入。
- **算法**：`sha256hex("${REDIS_CLUSTER_ID}:op-replica")`，简单、确定、跨组件可复现。

### ACL 用户按组件分离并在原行替换

- **原因**：server 只需要 `op-replica`，sentinel 只需要 `op-sentinel`；重写时保持文件中用户顺序稳定。
- **策略**：存在则原行替换，不存在则追加；`default` 用户始终保留。

### 固定创建日志目录但不写 `logfile`

- **原因**：当前阶段只读模板将日志配置为输出到 stdio，便于调试；固定创建 `/data/logs` 使未来切到文件日志时无需改脚本。

## Risks / Trade-offs

- **风险**：`REDIS_CLUSTER_ID` 变更后密码会变化，但按设计该 ID 在 CR 生命周期中不变。
- **风险**：ACL 文件若被外部工具以不兼容格式编辑，原行替换可能失效。
  - **缓解**：检查模式使用 `^user <username> `，仅替换匹配行；不匹配时追加。
- **风险**：Sentinel 实例之间认证依赖 Redis 7 的 `sentinel sentinel-user/pass`。
  - **缓解**：项目目标版本为 Redis 7，AGENT.md 中 AppPack 标识为 `redis-7`。
