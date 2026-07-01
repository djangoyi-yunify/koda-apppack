# Redis 配置文件持久化分析与建议

> 适用场景：在 Kubernetes 等容器环境中部署 Redis 主从复制 + Sentinel 高可用架构。

## 1. 背景问题

Redis 进程在运行期间会主动回写自身的配置文件，典型场景包括：

- 执行 `REPLICAOF` 命令建立或切换主从关系；
- 执行 `CONFIG SET` 后触发 `CONFIG REWRITE`；
- 执行 `ACL SETUSER` 等命令后调用 `ACL SAVE` 回写 ACL 文件；
- Sentinel 进行故障转移后，向 Redis 实例下发新的 `REPLICAOF` 并调用 `CONFIG REWRITE`。

这些回写行为在容器环境中会带来突出问题。下面分别看 Redis、Sentinel 和 `aclfile` 的实际情况。

### 1.1 Redis `redis.conf` 回写示例

假设初始配置文件如下：

```conf
# /etc/redis/redis.conf
maxmemory 1gb
appendonly yes
bind 0.0.0.0
requirepass defaultpass
```

执行故障转移后，Redis 实例被切换为某主库的副本，Sentinel 向其下发 `REPLICAOF redis-0.redis 6379` 并触发 `CONFIG REWRITE`，文件可能被改写为：

```conf
# /etc/redis/redis.conf
maxmemory 1gb
appendonly yes
bind 0.0.0.0
requirepass defaultpass

# 由 CONFIG REWRITE 自动追加
replicaof redis-0.redis 6379
masterauth masterpass
```

### 1.2 Sentinel `sentinel.conf` 回写示例

Sentinel 启动后，会不断重写自己的配置文件，记录运行时发现的拓扑信息：

```conf
# 初始配置（由运维/平台提供）
sentinel monitor mymaster redis-0.redis 6379 2
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 60000

# 运行后由 Sentinel 自动追加/更新
sentinel known-replica mymaster redis-1.redis 6379
sentinel known-replica mymaster redis-2.redis 6379
sentinel known-sentinel mymaster sentinel-1.redis 26379 e0e...hash...
sentinel known-sentinel mymaster sentinel-2.redis 26379 a1b...hash...
sentinel config-epoch mymaster 1
```

### 1.3 `aclfile` 回写问题

Redis 的 ACL 文件（`aclfile`）同样存在回写问题。当 ACL 规则发生变更并执行 `ACL SAVE` 时，Redis 会重写该文件：

- 执行 `ACL SETUSER`、`ACL DELUSER` 等命令后，内存中的 ACL 已变更，但文件尚未更新；
- 显式执行 `ACL SAVE`（或由脚本/控制面自动调用）后，`aclfile` 被回写。

如果 `aclfile` 在容器中以只读方式挂载，或挂载到 `emptyDir` 等临时存储，会出现两类问题：

1. **只读挂载时回写失败**：ACL 变更无法持久化，操作报错；
2. **未持久化时重启丢失**：Pod 重启后自定义用户、权限规则全部消失，可能导致认证失败或权限回退到初始状态。

需要注意的是，**主从复制不会同步 `aclfile` 的内容**，每个 Redis 节点需要独立维护自己的 ACL 文件。

### 1.4 容器环境中的共性问题

综上，这些配置文件在容器环境中都会带来两个共性问题：

1. **只读挂载的配置文件无法被回写**；
2. **可写但未持久化的配置文件在 Pod 重启后丢失**。

对于 Redis 而言，若 `redis.conf` 来自 ConfigMap 并以只读方式挂载，`CONFIG REWRITE` 会失败，运行时变更无法持久化；若 `redis.conf` 放在 `emptyDir` 等临时存储上，Pod 重启后文件被清空，Redis 按初始配置启动，可能以错误的角色加入集群。

`sentinel.conf` 与 `aclfile` 同理：前者未持久化会丢失拓扑认知，后者未持久化会丢失自定义用户与权限规则，均可能在重启后做出错误判断或导致认证失败。

## 2. 配置文件分类与持久化思路

针对不同类型的配置文件，推荐采用不同的持久化策略。

### 2.1 `redis.conf` / `sentinel.conf`：静态模板与动态运行配置分离

推荐将配置文件拆分为两部分：

- **静态模板**：由平台/运维人员维护，包含与运行拓扑无关的配置项，如 `maxmemory`、`appendonly`、`bind`、`requirepass` 等。以只读方式挂载。
- **动态运行配置**：包含 `replicaof`、`masterauth` 等会随拓扑变化的配置项。写入持久卷（创建与必要更新可由初始化容器中的脚本完成）。

一种有效的组织方式是让运行时生成的配置作为主文件，并通过 `include` 引入静态模板：

```text
# /data/redis-runtime.conf  <- 可写，位于持久卷
include /etc/redis/redis-template.conf
replicaof redis-0.redis 6379
```

启动命令：

```bash
redis-server /data/redis-runtime.conf
```

这种方式的优势：

- `CONFIG REWRITE` 只会重写主文件 `/data/redis-runtime.conf`，不会修改只读的 `/etc/redis/redis-template.conf`；
- Sentinel 变更 `replicaof` 后，变更会落盘到持久卷；
- Pod 重启后读取持久化的运行配置，能恢复正确的角色。

> 注意：若把静态模板作为主文件、动态配置通过 `include` 引入，则 `CONFIG REWRITE` 仍会把 `replicaof` 写回主文件（即静态模板），无法达到分离目的。

### 2.2 `aclfile`：配置在持久卷上

`aclfile` 不需要使用 `include` 做静态/动态分离，因为它本身就是运行时维护的动态文件。推荐直接将其路径配置在持久卷上，并确保 Redis 有写入权限（创建与必要更新可由初始化容器中的脚本完成）：

```conf
# redis.conf 中指定
aclfile /data/users.acl
```

启动后，Redis 会将 ACL 变更回写到 `/data/users.acl`，PVC 保证 Pod 重启后规则不丢失。

## 3. 部署建议

| 组件 | 配置文件 | 使用方式 | 是否持久化 | 更新者 |
|------|---------|---------|-----------|--------|
| Redis | `/etc/redis/redis-template.conf` | ConfigMap 只读挂载 | 否 | 控制面(模板渲染) |
| Redis | `/data/redis-runtime.conf` | 写入 PVC | 是 | Redis(CONFIG REWRITE) |
| Redis | `/data/users.acl` | 写入 PVC | 是 | Redis(ACL SAVE) |
| Sentinel | `/data/sentinel.conf` | 写入 PVC | 是 | Sentinel(自动重写) |

## 4. 运维注意事项

### 4.1 初始化容器负责动态配置的创建与更新

动态配置文件（`redis-runtime.conf`、`sentinel.conf`、`users.acl`）不是由平台直接挂载到 Pod 中，而是在 Pod 启动时由初始化容器中的脚本在持久化存储上创建。因此需要关注：

- **初始化脚本的正确性**：脚本必须根据当前集群拓扑生成正确的初始运行配置。如果脚本逻辑有误，Redis/Sentinel 启动时就会携带错误的角色、拓扑认知或 ACL 规则。
- **幂等性**：初始化脚本应优先检查持久化存储上是否已有有效的运行配置，避免在每次重启时盲目覆盖，导致已持久化的状态丢失。
- **失败处理**：若初始化容器执行失败，Pod 不应继续启动，否则可能以错误状态加入集群。

### 4.2 运行时回写失败需监控

Redis/Sentinel 在运行期间会主动回写动态配置文件。如果持久化存储满、文件权限错误或文件系统只读，回写会静默或显式失败。此时内存中的状态已经变更，但持久化存储上的文件仍是旧的，Pod 重启后将恢复到错误状态：

- `CONFIG REWRITE` 失败 → 重启后 Redis 角色错误；
- Sentinel 自动重写失败 → 重启后拓扑认知丢失；
- `ACL SAVE` 失败 → 重启后 ACL 规则回退。

建议通过监控或告警及时发现回写失败。

### 4.3 持久化存储重建与配置漂移

动态配置文件完全依赖持久化存储保存。如果删除或重建持久化存储，相关状态会回到初始化脚本生成的初始状态：

- `sentinel.conf` 丢失后，Sentinel 需要重新发现拓扑，期间可能做出错误判断；
- `users.acl` 丢失后，自定义用户与权限规则消失，可能导致认证失败；
- `redis-runtime.conf` 丢失后，Redis 可能以错误角色启动。

此外，经过多轮 failover 后，运行配置的内容会与初始模板产生差异。这是预期行为，但需要明确区分“初始期望配置”和“运行时持久化配置”，避免运维时混淆。重建持久化存储前，应做好备份或确认初始化脚本能够恢复正确状态。

## 5. 总结

在容器环境中部署 Redis + Sentinel 时，这些配置文件都需要认真对待持久化问题：

- **`redis.conf`**：采用“运行配置为主文件 + `include` 静态模板”的结构，并将运行配置放在持久卷上，确保 Pod 重启后能恢复正确角色。
- **`sentinel.conf`**：为每个 Sentinel 实例分配持久卷，让 Sentinel 自行维护和持久化拓扑信息。
- **`aclfile`**：直接写入持久卷，保证每个 Redis 节点独立维护的 ACL 规则在重启后可恢复。

三者共同点是：**把由运行时动态维护的状态与由平台/运维维护的静态期望配置分离，并确保动态状态在 Pod 重启后可恢复。**
