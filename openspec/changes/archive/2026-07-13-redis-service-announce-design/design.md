## Context

Redis AppPack 的初始化阶段由 `scripts/init.sh` 负责生成 `redis-runtime.conf`、`sentinel.conf` 与 ACL 文件；组件就绪后由 `postProvision` 建立复制关系，Sentinel 负责监控与故障转移。当前设计尚未明确 `replica-announce-ip` / `replica-announce-port` 的推导来源，导致复制、Sentinel 与外部客户端可能看到不同的地址。

`docs/research/kubeblocks-addons-redis-service-announce-approach.md` 显示，kubeblocks-addons 通过“容器内端口固定 + 外部 Service 动态宣告”解决了这个问题：Redis 始终监听固定容器端口，外部访问地址完全由 Service 类型决定，并写入 `replica-announce-*`。

Koda 当前现状与 kubeblocks-addons 的差异在 `docs/research/koda-vs-kubeblocks-redis-service-announce-env-var.md` 中已经梳理：Koda 的 `serviceFieldRef` 不支持 per-pod Service 聚合，`podService: true` 也尚未实际创建 Service。因此不能照搬 kubeblocks-addons，需要在 Koda 现有能力范围内做一次适配设计，并为未来 per-pod Service 预留扩展。

## Goals / Non-Goals

**Goals:**

- 统一 Redis `replica-announce-ip` / `replica-announce-port` 的推导来源：
  - 有外部 per-pod Service（NodePort / LoadBalancer / HostNetwork）时，从该 Service 推导；
  - 无外部 Service 时，回退到 Headless Service 给出的 Pod FQDN + 容器端口。
- Redis 主配置文件中的 `port` / `tls-port` 永远等于容器 `containerPort`。
- `init.sh` 在 Pod 重建时能够更新 announce 配置，并在启用 Sentinel 时修正 `replicaof` 指向当前 master。
- 脚本结构预留 per-pod NodePort / LoadBalancer 分支，未来 Koda 支持 `podService` 后可平滑接入。

**Non-Goals:**

- 在 Koda 控制面实现 per-pod Service 的自动创建（当前未实现）。
- 把默认 ClusterIP Service 作为 `replica-announce-*` 的来源。
- 支持运行时通过 `ComponentParameter` 修改 Redis 监听端口。
- 修改 Sentinel 自身的宣告配置（本设计只覆盖 redis-server）。

## Decisions

### 1. 外部 Service 仅限 per-pod 访问入口

```text
可用作 replica-announce 的来源：
  ├─ per-pod NodePort Service
  ├─ per-pod LoadBalancer Service
  └─ HostNetwork 模式（每个 Pod 独占主机端口）

不可用作 replica-announce 的来源：
  └─ 共享 ClusterIP / NodePort Service（所有 Pod 共用同一地址）
```

Rationale：共享 Service 会让多个副本宣告同一地址，Sentinel 会把该地址同时当作 master 和 replica，导致拓扑混乱。只有 per-pod 端点才能唯一标识一个 Redis 实例。

### 2. 当前阶段只实现 Headless 回退 + HostNetwork

Koda 的 `podService: true` 目前只会把 Service 标记为 `PendingServiceExport`，不会真正创建 per-pod Service。因此 NodePort / LoadBalancer 分支现在无法生效，只在脚本里预留解析函数。

当前实际生效的两条分支：

| 模式 | `replica-announce-ip` | `replica-announce-port` | 备注 |
|---|---|---|---|
| 默认（无外部 Service） | Pod FQDN via Headless | 容器端口 | 现在可用 |
| HostNetwork | Node IP | `REDIS_HOST_NETWORK_PORT` | 现在可用 |

未来 Koda 支持 per-pod Service 后，再加入 `REDIS_ADVERTISED_PORT`、`REDIS_LB_ADVERTISED_HOST` 等环境变量的 ordinal 匹配逻辑。

### 3. Redis 监听端口固定为容器端口

```text
ComponentDefinition 容器端口: containerPort: 6379
redis-runtime.conf:           port 6379  或  tls-port 6379
Service 端口:                 可任意，通过 targetPort: redis 转回 6379
replica-announce-port:        根据 Service 类型或 headless 确定
```

Rationale：容器端口是 Pod 模板中的静态契约，不可运行时被覆盖。把 Redis 监听端口锚定到容器端口，可以避免配置、Service 端口和容器端口三者不一致。

### 4. announce 配置在 `init.sh` 中生成

虽然 kubeblocks-addons 使用 `redis-start.sh` 在启动前动态生成，但 Koda 当前结构已经有 `init.sh` 负责准备主配置。把 announce 生成放入 `init.sh` 可以与现有职责对齐，同时保持主容器命令简洁（直接启动 `redis-server`）。

### 5. 使用独立的 `redis-announce.conf` 并通过 `include` 引入

```text
redis-runtime.conf
  ├─ include /etc/redis/redis-template.conf
  ├─ include /data/redis-announce.conf
  ├─ dir /data/redis
  ├─ aclfile /data/users.acl
  └─ masteruser / masterauth
```

Rationale：`redis-runtime.conf` 会被 Redis 自身的 `CONFIG REWRITE` 修改（写入 `replicaof`、`masterauth` 等），因此 `init.sh` 不能简单覆盖整个文件。把易变的 announce 配置拆到独立文件后，`init.sh` 可以在每次 Pod 重建时安全地覆盖 `redis-announce.conf`，而主配置中的运行时状态保持不变。

### 6. Pod 重建时查询 Sentinel 并修正 `replicaof`

启用 Sentinel 后，故障转移会导致 master 变更。如果旧 master 的 Pod 重建后仍按本地旧的 `replicaof` 启动，会尝试同步一个已经降级为 replica 的节点。因此 `init.sh` 在检测到 `redis-runtime.conf` 已存在时：

1. 连接 Sentinel（通过 Sentinel headless service 或已知 Sentinel 地址）；
2. 执行 `SENTINEL MASTER <master-name>` 获取当前 master 的地址；
3. 如果本地 announce 地址与当前 master 不同，则更新 `redis-runtime.conf` 中的 `replicaof` 行；
4. 首次创建（文件不存在）时跳过该步骤，因为此时 Sentinel 可能尚未初始化。

Rationale：把这一步放在 `init.sh` 可以在 Redis 进程启动前就摆正角色，避免启动后再由 Sentinel 重新配置带来的窗口期。

### 7. Headless FQDN 从 Pod 自身身份推导

由于 `serviceFieldRef` 不能引用 StatefulGroup 自动创建的 Headless Service，`init.sh` 不尝试从环境变量读取 headless service 信息，而是直接通过 Pod 自身身份构造 FQDN，例如：

```bash
# 方式一：依赖 K8s 设置的 subdomain
hostname -f
# 方式二：从环境变量组合
${HOSTNAME}.${KODA_HEADLESS_SERVICE}.${POD_NAMESPACE}.svc.cluster.local
```

优先使用 `hostname -f`，因为它不依赖额外的环境变量注入。

## Risks / Trade-offs

| Risk | Mitigation |
|---|---|
| `init.sh` 从“纯静态初始化”扩展到“拓扑修复”，职责边界变模糊 | 所有拓扑相关逻辑都只在 `redis-runtime.conf` 已存在时触发，并且完全由环境变量驱动，不调用 Koda API |
| Pod 重建时 Sentinel 尚未就绪，查询失败 | 定义失败策略：首次创建跳过；重建时若查询失败，可失败退出或按原配置继续（需进一步决策） |
| 环境变量是 Pod 创建时的快照，Service/LB 信息变化后不会自动更新 | 这是 Koda env 投影的已知限制；变更后需滚动重建 Pod 才能生效 |
| HostNetwork 端口由控制面分配，重建后可能变化 | 每次重建都会重新生成 `redis-announce.conf`，因此 announce-port 会同步更新 |
| 未来接入 per-pod NodePort/LB 时，脚本需要按 ordinal 匹配 Service | 现在把解析函数抽象好，未来只增加分支，不改动主流程 |

## Migration Plan

本次变更属于设计阶段，不涉及已部署实例迁移。后续实现时：

1. 更新 `scripts/init.sh`；
2. 更新 `ComponentDefinition` 环境变量与服务契约设计；
3. 补充单元测试与 E2E 测试用例；
4. 待 Koda 控制面支持 `podService` 后，再追加 NodePort / LoadBalancer 分支实现。

## Open Questions

1. Sentinel headless service 名与端口通过什么环境变量注入 `init.sh`？候选：
   - `KODA_SENTINEL_HEADLESS_SERVICE`：Sentinel 组件的 headless service 名；
   - `SENTINEL_PORT`：默认 `26379`。
2. Pod 重建时若 Sentinel 查询失败，是失败退出还是继续启动？需要结合 Sentinel 可用性 SLA 决定。
3. 是否需要给 redis-server 主容器增加一个兜底启动脚本，以防 `init.sh` 之外还需要动态修正？
