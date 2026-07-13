# Redis Init 容器初始化脚本设计

> 目标：为 Redis AppPack 提供一份与 Koda 控制面无关的初始化脚本，负责在 Pod 启动前准备主配置文件、ACL 文件及必要目录。

---

## 1. 背景

Redis 在容器环境中运行时，会主动回写主配置文件（`CONFIG REWRITE`、Sentinel 自动重写）和 ACL 文件（`ACL SAVE`）。为避免只读模板被污染、同时保证 Pod 重启后状态可恢复，采用"主配置文件 + `include` 只读模板"的分离方案。

本脚本在初始化容器中运行，在持久卷上创建：

- Redis 主配置文件（`redis-runtime.conf`）
- Sentinel 主配置文件（`sentinel.conf`）
- ACL 文件（`users.acl`）
- 必要的数据目录与日志目录

---

## 2. 设计目标

- **平台中立**：只依赖 Kubernetes 通用语义，不调用 Koda API，不依赖 Koda 特定的命名或状态。
- **职责单一**：只做初始化阶段必须做的事，不做角色判定、拓扑发现、业务用户创建等应由后续生命周期动作完成的事。
- **幂等安全**：支持 Pod 重启后重新执行，不覆盖已持久化的状态。
- **ACL 运维用户强制一致**：组件自身的运维用户（server 为 `op-replica`，sentinel 为 `op-sentinel`）每次初始化都重写，确保密码与 `REDIS_CLUSTER_ID` 对应；`default` 用户保留现有配置。

---

## 3. 中立性边界

脚本属于"通用 Kubernetes 初始化容器"层级：

- 不读取 Koda CRD、ConfigMap、Secret 的特定结构。
- 通过 Downward API 或标准 env 接收 Pod 名、命名空间等信息。
- 对 Koda 相关资源只做**名称假设**（如只读模板路径、headless service 名），具体值通过环境变量传入，可覆盖。

---

## 4. 前提假设

| 假设项 | 默认值 | 说明 |
|---|---|---|
| 只读模板路径 | `/etc/redis/redis-template.conf` | 来自 ConfigMap，以只读方式挂载 |
| 持久卷挂载点 | `/data` | 初始化脚本在该目录下创建文件与目录 |
| Redis 端口 | `6379` | 通过环境变量注入 |
| Sentinel 端口 | `26379` | 通过环境变量注入 |
| 固定源 | `REDIS_CLUSTER_ID` | 由平台注入，用于密码派生。可取 Koda CR 资源的名称或 UUID，要求在整个 CR 生命周期中保持不变且易于获取 |
| 日志输出 | stdio | 只读模板中配置日志输出到标准输出/错误，便于调试 |

---

## 5. 脚本接口

```bash
scripts/init.sh server
scripts/init.sh sentinel
```

脚本通过第一个参数区分组件类型，其他全部通过环境变量传入。

---

## 6. 环境变量

| 变量 | 默认值 | 必填 | 说明 |
|---|---|---|---|
| `REDIS_CLUSTER_ID` | - | 是 | 固定源，密码派生种子。建议取值自 Koda CR 名称或 UUID |
| `REDIS_TEMPLATE_PATH` | `/etc/redis/redis-template.conf` | 否 | 只读模板路径 |
| `REDIS_RUNTIME_CONFIG` | `/data/redis-runtime.conf` | 否 | Redis 主配置文件路径 |
| `SENTINEL_CONFIG` | `/data/sentinel.conf` | 否 | Sentinel 主配置文件路径 |
| `REDIS_ACL_FILE` | `/data/users.acl` | 否 | ACL 文件路径 |
| `REDIS_DATA_DIR` | `/data/redis` | 否 | Redis 数据目录 |
| `LOG_DIR` | `/data/logs` | 否 | 日志目录（固定创建，供未来使用） |
| `REDIS_PORT` | `6379` | 否 | Redis 端口 |
| `SENTINEL_PORT` | `26379` | 否 | Sentinel 端口 |
| `REDIS_HOST_NETWORK_PORT` | - | 否 | HostNetwork 模式下 Redis 被分配的主机端口，由 `hostNetworkFieldRef` 注入 |
| `CURRENT_POD_HOST_IP` | - | 否 | 当前 Pod 所在节点 IP，通过 downward API `status.hostIP` 注入 |
| `CURRENT_POD_IP` | - | 否 | 当前 Pod IP，通过 downward API `status.podIP` 注入 |
| `HOSTNAME` | - | 否 | Pod 名，如 `redis-server-0` |
| `POD_NAMESPACE` | - | 否 | Pod 所在命名空间 |
| `KODA_HEADLESS_SERVICE` | - | 否 | `redis-server` 组件的 headless service 名，用于构造 Pod FQDN |
| `KODA_SENTINEL_HEADLESS_SERVICE` | - | 否 | `redis-sentinel` 组件的 headless service 名，用于 Sentinel 查询 |
| `KODA_SENTINEL_REPLICAS` | `0` | 否 | Sentinel 副本数；大于 0 时表示启用 Sentinel |
| `KUBERNETES_CLUSTER_DOMAIN` | `cluster.local` | 否 | Kubernetes 集群域名 |

---

## 7. 密码派生

从固定源 `REDIS_CLUSTER_ID` 派生两个运维用户密码：

```text
op-replica  = sha256hex("${REDIS_CLUSTER_ID}:op-replica")
op-sentinel = sha256hex("${REDIS_CLUSTER_ID}:op-sentinel")
```

ACL 文件中使用 SHA256 哈希形式（`#<hash>`），避免明文存储。Sentinel 主配置文件中的 `sentinel sentinel-pass` 需要明文，由脚本在运行时从同一算法派生。

---

## 8. server 组件初始化

### 8.1 创建目录

```text
/data/redis
/data/logs
```

### 8.2 生成 Redis 主配置文件

文件路径：`/data/redis-runtime.conf`

```conf
include /etc/redis/redis-template.conf
include /data/redis-announce.conf
dir /data/redis
aclfile /data/users.acl
masteruser op-replica
masterauth <op-replica-password>
```

说明：

- 不写 `replicaof`，角色由 Koda provision 动作后续下发。
- `masteruser`/`masterauth` 用于 Redis 节点间复制认证。
- 通过 `include /data/redis-announce.conf` 引入易变的服务宣告配置，便于在 Pod 重建时独立更新，而不破坏主配置中的运行时状态。

### 8.3 生成服务宣告配置

文件路径：`/data/redis-announce.conf`

脚本根据当前 Pod 的身份和可选的外部 Service 信息，生成或覆盖该文件：

```conf
replica-announce-ip <resolved-ip>
replica-announce-port <resolved-port>
```

解析优先级：

1. **HostNetwork 模式**：若 `REDIS_HOST_NETWORK_PORT` 非空，则 `replica-announce-ip` 取 `CURRENT_POD_HOST_IP`（或 `CURRENT_POD_IP`），`replica-announce-port` 取 `REDIS_HOST_NETWORK_PORT`。
2. **per-pod NodePort Service（未来支持）**：若 `REDIS_ADVERTISED_PORT` 非空，按当前 Pod ordinal 匹配对应的 `svcName:nodePort`；命中后 `replica-announce-ip` 取节点 IP，`replica-announce-port` 取 nodePort。
3. **per-pod LoadBalancer Service（未来支持）**：若 `REDIS_LB_ADVERTISED_HOST` 与 `REDIS_LB_ADVERTISED_PORT` 非空，按 ordinal 匹配 LB ingress 与端口。
4. **Headless Service 回退**：无外部 Service 时，`replica-announce-ip` 取当前 Pod FQDN（优先 `hostname -f`，否则通过 `HOSTNAME` + `KODA_HEADLESS_SERVICE` 构造），`replica-announce-port` 取 `REDIS_PORT`。

每次 `init.sh server` 执行都会重新解析并覆盖 `redis-announce.conf`，因此 Pod 重建后 announce 值会自动刷新。

### 8.4 Pod 重建时的更新策略

`redis-runtime.conf` 中包含 Redis 进程回写的运行时状态（如 `replicaof`、`masterauth` 等），因此不能简单覆盖整个文件。Pod 重建时的更新策略为：

- **`redis-announce.conf`**：每次重新生成并覆盖，反映当前 Pod 最新的网络身份。
- **`redis-runtime.conf`**：首次创建时生成；已存在时保持主体内容不变，仅在启用 Sentinel 时允许更新 `replicaof` 行。
- **ACL 文件**：按第 10 节策略，组件自身运维用户原地替换重写，`default` 用户保留。

该策略保证 Pod 重建后：Redis 启动所需的新 announce 地址已就绪，而历史运行状态不丢失。

### 8.5 通过 Sentinel 修正 `replicaof`

当 `KODA_SENTINEL_REPLICAS` 大于 0 且 `redis-runtime.conf` 已存在时，脚本会在启动前连接 Sentinel 查询当前 master，并原地修正 `replicaof`：

1. 构造 Sentinel 实例地址：从 `KODA_SENTINEL_HEADLESS_SERVICE` 推导前缀，按 `KODA_SENTINEL_REPLICAS` 遍历 `prefix-0.headless`、`prefix-1.headless` 等。
2. 使用 `op-sentinel` 用户执行 `SENTINEL MASTER ${REDIS_CLUSTER_ID}-master`。
3. 解析返回结果中的 `ip` 与 `port`。
4. 若解析出的 master 与当前 Pod 自身 announce 地址一致，则移除 `redis-runtime.conf` 中的 `replicaof`；否则写入/替换 `replicaof <master-ip> <master-port>`。

首次创建时跳过该步骤，因为此时 Sentinel 可能尚未初始化。

若 Sentinel 查询失败（例如 Sentinel 尚未就绪），脚本会打印告警并保留现有 `replicaof`，不阻塞启动。

### 8.6 初始化 ACL 文件

确保 `/data/users.acl` 内容如下：

```conf
user op-replica on #<hash> ~* &* +@all
user default off
```

- `op-replica`：若已存在，则在原行直接替换为新的密码哈希；若不存在，在文件末尾追加。
- `default`：若已存在则保留原内容，不存在时追加 `user default off`。

server 组件的 ACL 文件不需要 `op-sentinel` 用户。

---

## 9. sentinel 组件初始化

### 9.1 创建目录

```text
/data/logs
```

不创建 `/data/sentinel` 数据目录，因为 Sentinel 状态全部回写到 `sentinel.conf`。

### 9.2 生成 Sentinel 主配置文件

文件路径：`/data/sentinel.conf`

```conf
port 26379
aclfile /data/users.acl
sentinel sentinel-user op-sentinel
sentinel sentinel-pass <op-sentinel-password>
```

说明：

- 不写 `sentinel monitor` 和 quorum，由 Koda provision 动作后续下发。
- `sentinel sentinel-user`/`sentinel sentinel-pass` 用于 Sentinel 实例之间的认证（Redis 7 特性）。

### 9.3 初始化 ACL 文件

确保 `/data/users.acl` 内容如下：

```conf
user op-sentinel on #<hash> ~* &* +@all
user default off
```

- `op-sentinel`：若已存在，则在原行直接替换为新的密码哈希；若不存在，在文件末尾追加。
- `default`：若已存在则保留原内容，不存在时追加 `user default off`。

sentinel 组件的 ACL 文件不需要 `op-replica` 用户。

---

## 10. ACL 初始化策略

脚本对 ACL 文件的初始化策略按组件区分：

### server 组件

1. 若 ACL 文件不存在，先 `touch` 创建空文件。
2. 查找以 `user op-replica ` 开头的行：
   - 若存在，直接在该行替换为新的 `op-replica` 定义（保持原有位置）。
   - 若不存在，在文件末尾追加新的 `op-replica` 定义。
3. 若 `user default ` 行不存在，追加 `user default off`；已存在则保留原内容。

### sentinel 组件

1. 若 ACL 文件不存在，先 `touch` 创建空文件。
2. 查找以 `user op-sentinel ` 开头的行：
   - 若存在，直接在该行替换为新的 `op-sentinel` 定义（保持原有位置）。
   - 若不存在，在文件末尾追加新的 `op-sentinel` 定义。
3. 若 `user default ` 行不存在，追加 `user default off`；已存在则保留原内容。

### 通用原则

- 检查模式使用 `^user <username> `，避免误匹配注释行。
- 组件自身的运维用户每次初始化都重写，确保与 `REDIS_CLUSTER_ID` 严格对应。
- 重写时直接在原行替换，不删除后追加，以保持文件中用户顺序。
- `default` 用户可能由后续生命周期动作或管理员调整，应予以保留。
- 不写入其他组件的运维用户。

---

## 11. 幂等性

脚本整体遵循"逐项检查、逐项创建"，但 ACL 文件中的组件自身运维用户例外：

- 目录不存在 → `mkdir -p`
- 主配置文件不存在 → 生成
- server 组件：ACL 文件中的 `op-replica` → 每次在原行替换重写
- sentinel 组件：ACL 文件中的 `op-sentinel` → 每次在原行替换重写
- ACL 文件中的 `default` 用户 → 存在则保留，不存在则追加 `user default off`

Pod 重启后再次执行 init 脚本，不会破坏 Redis/Sentinel 已持久化的运行状态。

---

## 12. 明确不处理的事项

以下事项不在 init 脚本职责范围内，由 Koda 生命周期动作（provision / accountProvision 等）后续处理：

- 首次启动时主从角色判定与 `replicaof` 配置
- `sentinel monitor` 与 quorum 配置
- Sentinel 到 Redis 的认证配置
- 业务用户/密码的创建与变更

> 注：Pod 重建时，`init.sh` 会在启用 Sentinel 的场景下查询当前 master 并更新 `replicaof`。这不属于首次角色判定，而是对既有运行状态的修复。

---

## 13. 文件输出汇总

### server Pod

```text
/data/redis-runtime.conf   # Redis 主配置文件（包含 include redis-announce.conf）
/data/redis-announce.conf  # 服务宣告配置（replica-announce-ip/port）
/data/users.acl            # ACL 文件
/data/redis/               # 数据目录
/data/logs/                # 日志目录
```

### sentinel Pod

```text
/data/sentinel.conf        # Sentinel 主配置文件
/data/users.acl            # ACL 文件
/data/logs/                # 日志目录
```

---

## 14. 依赖

- Redis 7.x（使用 `sentinel sentinel-user`/`sentinel sentinel-pass`）
- Bash（项目统一使用 Bash 脚本）
- 标准 Linux 工具：`sha256sum`、`grep`、`mkdir`、`touch`
