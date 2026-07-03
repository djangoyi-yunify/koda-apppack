## Context

Redis AppPack 第一阶段只支持 replication + Sentinel 拓扑。仓库已有 `scripts/init.sh` 负责 init 容器阶段：创建 `redis-runtime.conf`、`sentinel.conf`、`users.acl`，并初始化 operator 账号。组件启动后，Sentinel 还不知道要监控哪个 master，replica 也没有被动态指向 primary。`postProvision` 是 Koda `lifecycle.actions` 中组件就绪后的一次性钩子，正好用来补齐这两件事。

本次变更引入统一脚本 `scripts/lifecycle.sh`，由 Koda 通过 `$1` 传入动作名进行分发。本次仅实现 `postProvision`，其余动作预留扩展点。

## Goals / Non-Goals

**Goals：**

- 提供单一生命周期动作脚本入口 `scripts/lifecycle.sh`；
- 实现 `postProvision` 分支，完成 Redis 组件启动后的拓扑初始化：
  - `redis-server`：ordinal ≠ 0 时执行 `REPLICAOF`；
  - `redis-sentinel`：执行 `SENTINEL MONITOR`、quorum、auth-user、auth-pass；
- 脚本行为幂等，支持 `targetPodSelector: All`；
- 输出结构化 JSON，错误退出前必须先输出合法 JSON。

**Non-Goals：**

- 不实现 `roleProbe`、`availableProbe`、`switchover`、`memberJoin`、`memberLeave`、`reconfigure`；
- 不修改 `scripts/init.sh`；
- 不引入新的账号体系，复用 `init.sh` 创建的 `op-replica` 与 `op-sentinel`；
- 不调用 `SENTINEL FLUSH CONFIG`，依赖 Sentinel 自动回写。

## Decisions

### 1. 统一脚本入口

**决策**：所有生命周期动作使用同一个脚本 `scripts/lifecycle.sh`，通过 `$1` 路由。

**理由**：
- 减少脚本文件数量，便于维护；
- 动作间可共享工具函数（密码推导、JSON 输出、错误处理）；
- 与 Koda exec action 调用形态天然匹配：`command: [/scripts/lifecycle.sh, postProvision, '{}']`。

**替代方案**：每个动作一个脚本。放弃原因：当前动作数量多，文件碎片化，公共逻辑难以复用。

### 2. 参数与输入

**决策**：`$1` 为动作名，`$2` 为 JSON 参数，`postProvision` 的 `$2` 固定为 `{}`；动作所需信息由环境变量 + 脚本推导提供。

**理由**：
- `postProvision` 所需信息（componentType、clusterId、headless service 等）都是运行时上下文，由 Koda 注入环境变量最自然；
- 统一 `$1`/`$2` 接口，未来动作扩展时 schema 清晰；
- 不支持 stdin，保持接口简单。

### 3. 退出码与输出

**决策**：退出码 `0` 表示成功，非 `0` 表示失败；stdout 输出 `{status, message, error}` JSON；失败退出前必须先输出 JSON。

**理由**：
- wrapper 可把 exit code 直接映射为 Koda action 成功/失败；
- stdout JSON 提供结构化错误信息，便于 Koda 写入 `ActionResponse.message`；
- 失败前输出 JSON 防止 wrapper 解析空输出。

### 4. redis-server 分支在 ordinal ≠ 0 执行 REPLICAOF

**决策**：`redis-server` 的 `postProvision` 在 `targetPodSelector: All` 下对所有实例执行，ordinal 0 跳过，其余执行 `REPLICAOF <master-fqdn> <port>`。

**理由**：
- 每个 replica 需要独立知道 primary 地址；
- `REPLICAOF` 命令本身幂等，重复执行安全；
- master 的 `masteruser`/`masterauth` 已由 `init.sh` 写入配置，无需额外 ACL 操作。

### 5. redis-sentinel 分支显式配置每个 sentinel

**决策**：`redis-sentinel` 的 `postProvision` 使用 `targetPodSelector: All`，每个 sentinel 都执行 `SENTINEL MONITOR` + auth 配置。

**理由**：
- Sentinel 的 gossip 机制用于发现其他 sentinel（`known-sentinel`）和 replica（`known-replica`），但**不会**把某个 sentinel 正在监控的 master 配置传播给其他 sentinel；
- 每个 sentinel 必须独立被告知要监控哪个 master，否则该 sentinel 不会参与该 master 的故障检测与 failover；
- 脚本先 `SENTINEL MASTER` 检查，配合并发竞争容错，保证幂等。

### 6. 密码推导复用 init.sh 规则

**决策**：脚本使用与 `init.sh` 相同的 SHA-256 推导函数生成 `op-replica` 与 `op-sentinel` 密码。

**理由**：
- 无需 Koda 直接传入明文密码；
- 保证 init 容器创建 ACL 与 lifecycle 动作使用同一密码；
- 符合“保持中立”原则：脚本内部管理自己的认证模型。

### 7. 不调用 SENTINEL FLUSH CONFIG

**决策**：配置 sentinel monitor 后不显式 flush，依赖 Sentinel 自动回写 `sentinel.conf`。

**理由**：
- Sentinel 会周期性自动重写配置文件，记录 monitor、known-replica、known-sentinel 等状态；
- `sentinel.conf` 已位于持久卷，Pod 重启后可恢复；
- 减少脚本对 Sentinel 版本特定命令的依赖。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| Sentinel 并发执行 SENTINEL MONITOR 时可能冲突 | 脚本先查询，若已存在则跳过；若查询与创建之间并发冲突，按 already monitored 错误处理为成功。 |
| HOSTNAME 不符合 name-ordinal 格式导致 ordinal 推导错误 | 脚本校验 HOSTNAME 格式，无法推导时输出明确错误 JSON 并退出。 |
| Koda 未注入所需环境变量 | 脚本在开头校验必填变量，缺失时立即失败并输出 JSON。 |
| 脚本错误退出前未输出 JSON | 统一错误出口函数 fail_json，所有错误路径都经此退出。 |
| 后续动作扩展时脚本变大 | 按动作分函数，公共逻辑抽离为 helper，保持可维护。 |
