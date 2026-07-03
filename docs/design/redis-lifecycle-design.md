# Redis AppPack 生命周期动作设计

> 本文档聚焦 Redis replication + Sentinel 拓扑下的生命周期动作脚本设计。
> 目标中间件：Redis 7.x
> 相关文档：`docs/design/redis-apppack-plan.md`、`docs/research/redis-config-persistence-analysis.md`

---

## 1. 设计目标

为 Koda 平台提供一个**统一的生命周期动作脚本入口**，处理 Redis AppPack 所有组件级生命周期动作。

本次变更仅实现 `postProvision`，其余动作（`roleProbe`、`availableProbe`、`switchover`、`memberJoin`、`memberLeave`、`reconfigure` 等）在本次变更中不实现，但脚本结构上预留扩展点。

---

## 2. 脚本位置与入口契约

脚本路径：

```text
scripts/lifecycle.sh      # 统一入口分发器
scripts/helper.sh         # 公共 helper 函数库
scripts/actions/*.sh      # 各动作函数库
```

`scripts/lifecycle.sh` 是薄分发器，负责加载公共 helper 和所有 action 函数库，并根据 `$1` 调用对应的函数。具体的动作实现按动作拆分到 `scripts/actions/` 目录下的独立文件中。

调用方式（外部契约不变）：

```bash
./lifecycle.sh <action-name> <json-params>
```

| 位置 | 含义 | 示例 |
|---|---|---|
| `$1` | 动作名称 | `postProvision` |
| `$2` | 动作参数，JSON 格式 | `postProvision` 传 `{}` |

约束：

- 不支持 stdin 管道传入参数；
- `$1` 必填，`$2` 必填但允许为 `{}`；
- 所有 `postProvision` 所需信息由环境变量提供或脚本自行推导，`$2` 不解析；
- 禁止直接执行 `scripts/actions/*.sh`，它们只作为函数库被 `lifecycle.sh` source。

---

## 3. 动作分发

`lifecycle.sh` 在加载 `helper.sh` 和所有 action 函数库后，按 `$1` 调用同名函数完成分发：

```text
source scripts/helper.sh
source scripts/actions/post-provision.sh
source scripts/actions/role-probe.sh
...

case $ACTION in
  postProvision)
    postProvision
    ;;
  roleProbe)
    roleProbe
    ;;
  availableProbe)
    availableProbe
    ;;
  switchover)
    switchover
    ;;
  memberJoin)
    memberJoin
    ;;
  memberLeave)
    memberLeave
    ;;
  reconfigure)
    reconfigure
    ;;
  "")
    fail_json "Missing action name in \$1" ""
    ;;
  *)
    fail_json "Unknown action: ${ACTION}" ""
    ;;
esac
```

函数名与 action 名保持一致，dispatch 逻辑直观且无需命名转换。未实现的 action 由对应占位函数返回失败 JSON；空 `$1` 或未知 action 由分发器统一返回失败 JSON。

`ComponentDefinition` 本次仅声明 `lifecycle.actions.postProvision`，其他动作暂不在定义层出现。

### 3.1 Action 脚本约定

- `scripts/actions/*.sh` 只定义函数，不写顶层执行代码；
- action 脚本文件没有 shebang、不设置可执行权限，禁止作为独立入口直接运行；
- 所有 action 函数都在 `lifecycle.sh` 的同一 shell 环境中被 source，因此可以直接使用 `helper.sh` 提供的公共函数以及 `lifecycle.sh` 中准备的环境变量。

---

## 4. postProvision 设计

`postProvision` 是组件就绪后执行的一次性初始化动作。

### 4.1 职责划分

| 组件 | 职责 |
|---|---|
| `redis-server` | 在 ordinal ≠ 0 的节点上执行 `REPLICAOF`，使其复制 primary。 |
| `redis-sentinel` | 执行 `SENTINEL MONITOR`，配置 quorum、auth-user、auth-pass。 |

### 4.2 targetPodSelector

| 组件 | selector | 说明 |
|---|---|---|
| `redis-server` | `All` | 每个 replica 都需要知道 primary 是谁；ordinal 0 自行跳过。 |
| `redis-sentinel` | `All` | Sentinel gossip 只传播 `known-sentinel` 和 `known-replica`，不传播 master 监控配置；每个 sentinel 必须独立配置 monitor。脚本幂等，并发安全。 |

### 4.3 环境变量

| 变量 | 是否必填 | 说明 |
|---|---|---|
| `KODA_COMPONENT_TYPE` | 必填 | `redis-server` 或 `redis-sentinel` |
| `REDIS_CLUSTER_ID` | 必填 | 集群标识，用于密码推导与 masterName 生成 |
| `KODA_HEADLESS_SERVICE` | 必填 | `redis-server` 组件的 headless 服务名 |
| `HOSTNAME` | K8s 注入 | Pod 名，如 `redis-server-2`，用于推导 ordinal |
| `KODA_SENTINEL_REPLICAS` | sentinel 必填 | sentinel 副本数，用于推导 quorum |
| `REDIS_PORT` | 可选 | 默认 `6379` |
| `SENTINEL_PORT` | 可选 | 默认 `26379` |

### 4.4 脚本推导逻辑

```text
ordinal      = ${HOSTNAME##*-}
master_name  = "${REDIS_CLUSTER_ID}-master"
master_fqdn  = "redis-server-0.${KODA_HEADLESS_SERVICE}"
quorum       = (KODA_SENTINEL_REPLICAS / 2) + 1     # 整数除法

op_replica_pass  = sha256("${REDIS_CLUSTER_ID}:op-replica")
op_sentinel_pass = sha256("${REDIS_CLUSTER_ID}:op-sentinel")
```

密码推导算法与 `scripts/init.sh` 保持一致：

```bash
printf '%s' "${REDIS_CLUSTER_ID}:${username}" | sha256sum | awk '{print $1}'
```

### 4.5 redis-server 分支

```text
if ordinal == 0:
    输出 success，跳过 replicaof
else:
    使用 op-replica 用户连接本地 Redis
    执行 REPLICAOF ${master_fqdn} ${REDIS_PORT}
```

`masteruser` 与 `masterauth` 已由 `init.sh` 写入 `redis-runtime.conf`，此处无需额外 ACL 操作。

### 4.6 redis-sentinel 分支

```text
使用 op-sentinel 用户连接本地 Sentinel

if SENTINEL MASTER ${master_name} 不存在:
    尝试执行 SENTINEL MONITOR ${master_name} ${master_fqdn} ${REDIS_PORT} ${quorum}
    若返回 "already monitored" 类错误，视为成功（并发竞争场景）

执行（幂等）:
    SENTINEL SET ${master_name} auth-user op-replica
    SENTINEL SET ${master_name} auth-pass ${op_replica_pass}
```

不调用 `SENTINEL FLUSH CONFIG`，依赖 Sentinel 自动回写 `sentinel.conf`。`sentinel.conf` 位于持久卷，相关分析见 `docs/research/redis-config-persistence-analysis.md`。

> **为什么 sentinel 也需要 `targetPodSelector: All`**：Sentinel 的 gossip 机制仅用于发现其他 sentinel（`known-sentinel`）和 replica（`known-replica`），并不会把某个 sentinel 正在监控的 master 配置传播给其他 sentinel。每个 sentinel 必须独立被告知要监控哪个 master，否则它不会参与该 master 的故障检测与 failover。

---

## 5. 输出格式

脚本向 stdout 输出 JSON，结构固定为三个字段：

```json
{"status":"success","message":"...","error":""}
{"status":"failure","message":"...","error":"..."}
```

| 字段 | 说明 |
|---|---|
| `status` | `success` 或 `failure` |
| `message` | 人类可读的结果摘要 |
| `error` | 成功时为空字符串，失败时为具体错误信息 |

---

## 6. 退出码规则

| 退出码 | 含义 |
|---|---|
| `0` | 成功 |
| 非 `0` | 失败 |

**关键约束**：任何因错误导致的退出前，必须先向 stdout 输出合法的失败 JSON。不允许出现 "exit 非 0 但 stdout 为空或乱码" 的情况。

示例错误出口：

```text
fail(message, error) {
    输出 {"status":"failure","message":"...","error":"..."}
    exit 1
}
```

---

## 7. 幂等性

| 操作 | 幂等策略 |
|---|---|
| `REPLICAOF` | Redis 命令本身幂等，重复执行无伤害。 |
| `SENTINEL MONITOR` | 非幂等。脚本先通过 `SENTINEL MASTER` 检查；若并发竞争导致创建失败，按已存在处理。 |
| `SENTINEL SET auth-user/auth-pass` | 幂等，重复设置相同值无伤害。 |

---

## 8. 与 init.sh 的关系

- `scripts/init.sh` 负责 init 容器阶段：创建 `redis-runtime.conf`、`sentinel.conf`、`users.acl`，并初始化 operator 账号；
- `scripts/lifecycle.sh` 负责组件就绪后的运行时动作；
- 两者共享密码推导规则，确保 operator 账号密码一致。

---

## 9. 未实现动作（本次变更外）

以下动作在本次变更中不实现，但脚本接口已预留：

- `roleProbe`
- `availableProbe`
- `switchover`
- `memberJoin`
- `memberLeave`
- `reconfigure`

这些动作未来会逐步加入 `scripts/lifecycle.sh`，并在 `ComponentDefinition` 中声明。

---

## 10. 安全说明

脚本使用 `op-replica` 与 `op-sentinel` 两个 operator 账号执行管理命令。这两个账号在 `init.sh` 中通过 ACL 授予 `+@all` 权限。密码由 `REDIS_CLUSTER_ID` 与用户名经 SHA-256 推导，不依赖 Koda 直接传入明文密码。
