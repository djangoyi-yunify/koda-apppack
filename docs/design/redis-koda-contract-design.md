# Redis AppPack 与 Koda 新契约设计

> 目标：基于 Koda 原生能力，重新定义 Redis AppPack（replication + Sentinel）与 Koda 控制面之间的环境变量与动作契约。
> 设计范围：`scripts/init.sh`、`scripts/lifecycle.sh`、`ComponentDefinition`、`ApplicationDefinition`。
> 相关调研：`docs/research/koda-support-assessment.md`

---

## 1. 设计目标

1. **充分利用 Koda 原生能力**：使用 `systemAccounts`、`componentFieldRef`、`credentialFieldRef`、`applicationFieldRef` 替代自定义约定（如 `REDIS_CLUSTER_ID`）。
2. **消除对 Headless Service 名称的硬编码依赖**：通过 `componentFieldRef.podFQDNs` 发现 Pod。
3. **保证启动时序正确**：Redis 启动前即可读到系统账号密码，避免 replica 无法认证 master。
4. **保持脚本平台中立**：脚本仍只依赖标准 K8s 注入的环境变量，不直接调用 Koda API。

---

## 2. 设计原则

```
┌─────────────────────────────────────────────────────────────┐
│                     新契约设计原则                            │
├─────────────────────────────────────────────────────────────┤
│ 1. 能由 Koda 生成的，就不在脚本里派生。                        │
│ 2. 组件身份用 shortName，而不是自定义 type 字段。              │
│ 3. 网络发现用 Pod FQDN，而不是服务名。                        │
│ 4. 密码由 Koda 生成并通过 SecretKeyRef 注入。                 │
│ 5. 所有变量在 ComponentDefinition 中显式声明。                 │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. 总体架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                          Application (Redis Cluster)                 │
│                              name: myapp                               │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
        ┌───────────────────────┼───────────────────────┐
        ▼                       ▼                       ▼
┌───────────────┐      ┌───────────────┐      ┌───────────────┐
│ redis-server  │      │ redis-sentinel│      │ redis-exporter│
│ Component     │      │ Component     │      │ Component     │
└───────┬───────┘      └───────┬───────┘      └───────┬───────┘
        │                       │                       │
        ▼                       ▼                       ▼
┌───────────────┐      ┌───────────────┐      ┌───────────────┐
│ StatefulGroup │      │ StatefulGroup │      │ StatefulGroup │
│ (replicas=N)  │      │ (replicas=3)  │      │ (replicas=1)  │
└───────────────┘      └───────────────┘      └───────────────┘
```

---

## 4. 系统账号设计

### 4.1 账号定义

在 `ComponentDefinition` 中声明两个系统账号：

| 账号名 | 用途 | 作用组件 |
|---|---|---|
| `op-replica` | Redis 组件内部运维账号，用于 master-replica 认证、ACL 管理 | `redis-server` |
| `op-sentinel` | Sentinel 组件内部运维账号，用于 Sentinel 之间认证、ACL 管理 | `redis-sentinel` |

### 4.2 为什么不用 `initAccount: true`

如果设置 `initAccount: true`，Koda 不会为该账号创建 Secret，也不会触发 `accountProvision` 动作。密码完全由 init.sh 决定，这与“由 Koda 管理密码”的目标冲突。

**因此保持 `initAccount: false`（默认）。**

### 4.3 密码注入启动时序

```
ComponentDefinition 声明 op-replica / op-sentinel
        ↓
Component 控制器创建 Secret：
  myapp-redis-server-account-op-replica
  myapp-redis-sentinel-account-op-sentinel
        ↓
Pod Template 通过 CredentialFieldRef 把密码作为 SecretKeyRef 注入
        ↓
init 容器启动，从环境变量读取密码，写入 redis-runtime.conf / sentinel.conf / users.acl
        ↓
Redis / Sentinel 主容器启动，使用配置中的密码
        ↓
Pod Ready 后，Koda 通过 agent 调用 accountProvision 动作，幂等地创建/更新 ACL 用户
```

### 4.4 ComponentDefinition 中的声明示例

```yaml
spec:
  contracts:
    credential:
      systemAccounts:
        - name: op-replica
          statements:
            create: "~* &* +@all"
            update: "~* &* +@all"
            delete: ""
          passwordPolicy:
            generation: platform
        - name: op-sentinel
          statements:
            create: "~* &* +@all"
            update: "~* &* +@all"
            delete: ""
          passwordPolicy:
            generation: platform
  lifecycle:
    actions:
      accountProvision:
        exec:
          command: ["/scripts/lifecycle.sh", "accountProvision"]
        targetPodSelector: All
```

### 4.5 环境变量注入示例

```yaml
spec:
  env:
    - name: OP_REPLICA_PASSWORD
      valueFrom:
        credentialFieldRef:
          name: op-replica
          password: Required
    - name: OP_SENTINEL_PASSWORD
      valueFrom:
        credentialFieldRef:
          name: op-sentinel
          password: Required
```

### 4.6 init.sh 中的使用

```bash
# 不再派生密码，直接读取 Koda 注入的密码
ensure_acl_user "$REDIS_ACL_FILE" "op-replica" \
  "user op-replica on #$(echo -n "$OP_REPLICA_PASSWORD" | sha256sum | awk '{print $1}') ~* &* +@all"
```

> 注意：Redis ACL 密码存储的是 SHA-256 哈希，但 Koda 注入的是明文密码。init.sh 需要在写入 ACL 文件前对密码做哈希。

---

## 5. 组件身份设计

### 5.1 变量：`KODA_COMPONENT_NAME`

| 属性 | 值 |
|---|---|
| 变量名 | `KODA_COMPONENT_NAME` |
| 来源 | `componentFieldRef.shortName` |
| 取值 | `redis-server` / `sentinel` / `redis-exporter` |
| 用途 | 脚本中区分当前是 server、sentinel 还是 exporter |

### 5.2 为什么不使用 `componentFieldRef.componentName`

`componentName` 返回完整 Component CR 名，例如 `myapp-redis-server`，不适合作为脚本内部标识。`shortName` 返回 slot 名，即 `redis-server`。

### 5.3 ComponentDefinition 声明示例

```yaml
spec:
  env:
    - name: KODA_COMPONENT_NAME
      valueFrom:
        componentFieldRef:
          componentName: ""
          shortName: Required
```

### 5.4 脚本中的使用

```bash
case "$KODA_COMPONENT_NAME" in
  redis-server)
    init_server
    ;;
  sentinel)
    init_sentinel
    ;;
  redis-exporter)
    init_exporter
    ;;
esac
```

---

## 6. Pod 发现设计

### 6.1 变量：`KODA_COMPONENT_POD_NAME` 与 `KODA_COMPONENT_POD_FQDNS`

| 变量名 | 来源 | 示例值（redis-server，replicas=3） |
|---|---|---|
| `KODA_COMPONENT_POD_NAME` | `componentFieldRef.podNames` | `myapp-redis-server-0,myapp-redis-server-1,myapp-redis-server-2` |
| `KODA_COMPONENT_POD_FQDNS` | `componentFieldRef.podFQDNs` | `myapp-redis-server-0.myapp-redis-server-headless.default.svc.cluster.local,...` |

### 6.2 当前组件 vs 跨组件引用

- `redis-server` 组件引用自己的 `podFQDNs`：用于初始化时识别自身所在副本集。
- `redis-sentinel` 组件需要引用 `redis-server` 组件的 `podFQDNs`：用于初始发现 master。

```yaml
# redis-sentinel ComponentDefinition
spec:
  env:
    - name: KODA_REDIS_SERVER_POD_FQDNS
      valueFrom:
        componentFieldRef:
          componentName: redis-server   # 引用同 Application 下的 redis-server slot
          podFQDNs: Required
```

### 6.3 init.sh 中的使用

```bash
# 获取当前 Pod 的 FQDN
get_pod_fqdn() {
  lookup_value_by_ordinal "$KODA_COMPONENT_POD_FQDNS" "$HOSTNAME"
}

# 获取初始 master FQDN（ordinal 0）
get_initial_master_fqdn() {
  local first_fqdn
  first_fqdn="${KODA_COMPONENT_POD_FQDNS%%,*}"
  printf '%s' "$first_fqdn"
}
```

### 6.4 为什么不需要 `KODA_HEADLESS_SERVICE`

Pod FQDN 已经包含了 Headless Service 的 DNS 信息。脚本只需要按 ordinal 从 FQDN 列表中匹配当前 Pod，即可获得自身的完整网络标识。

---

## 7. Master 名称设计

### 7.1 替换 `REDIS_CLUSTER_ID`

由于去掉了 `REDIS_CLUSTER_ID`，需要新的稳定标识来命名 Sentinel 监控的 master。

**建议**：使用 Application 名称作为 master-name 前缀：

```bash
master_name="${KODA_APPLICATION_NAME}-master"
```

### 7.2 变量：`KODA_APPLICATION_NAME`

| 属性 | 值 |
|---|---|
| 变量名 | `KODA_APPLICATION_NAME` |
| 来源 | `applicationFieldRef.applicationName` |
| 用途 | Sentinel master-name 前缀 |

```yaml
spec:
  env:
    - name: KODA_APPLICATION_NAME
      valueFrom:
        applicationFieldRef:
          applicationName: Required
```

### 7.3 唯一性假设

本设计假设：**一个 Application 中只有一个 Redis 集群**。如果未来需要在一个 Application 中运行多个 Redis 集群，需要引入实例名（instance name）作为 master-name 的第二级前缀。

---

## 8. 环境变量契约总览

### 8.1 redis-server ComponentDefinition

```yaml
spec:
  type: redis-server
  engine:
    kind: redis
    version: "7.2"
  contracts:
    credential:
      systemAccounts:
        - name: op-replica
          statements:
            create: "~* &* +@all"
            update: "~* &* +@all"
          passwordPolicy:
            generation: platform
    services:
      exports:
        - name: redis
          serviceSpec:
            type: ClusterIP
            ports:
              - name: redis
                port: 6379
                targetPort: redis
  env:
    - name: KODA_COMPONENT_NAME
      valueFrom:
        componentFieldRef:
          shortName: Required
    - name: KODA_APPLICATION_NAME
      valueFrom:
        applicationFieldRef:
          applicationName: Required
    - name: KODA_COMPONENT_POD_NAME
      valueFrom:
        componentFieldRef:
          podNames: Required
    - name: KODA_COMPONENT_POD_FQDNS
      valueFrom:
        componentFieldRef:
          podFQDNs: Required
    - name: OP_REPLICA_PASSWORD
      valueFrom:
        credentialFieldRef:
          name: op-replica
          password: Required
    - name: REDIS_PORT
      value: "6379"
    - name: HOSTNAME
      valueFrom:
        fieldRef:
          fieldPath: metadata.name
    - name: POD_NAMESPACE
      valueFrom:
        fieldRef:
          fieldPath: metadata.namespace
    - name: CURRENT_POD_IP
      valueFrom:
        fieldRef:
          fieldPath: status.podIP
    - name: CURRENT_POD_HOST_IP
      valueFrom:
        fieldRef:
          fieldPath: status.hostIP
  lifecycle:
    actions:
      postProvision:
        exec:
          command: ["/scripts/lifecycle.sh", "postProvision"]
        targetPodSelector: All
      accountProvision:
        exec:
          command: ["/scripts/lifecycle.sh", "accountProvision"]
        targetPodSelector: All
      roleProbe:
        exec:
          command: ["/scripts/lifecycle.sh", "roleProbe"]
        targetPodSelector: All
        initialDelaySeconds: 5
        periodSeconds: 10
      availableProbe:
        exec:
          command: ["/scripts/lifecycle.sh", "availableProbe"]
        targetPodSelector: All
        initialDelaySeconds: 5
        periodSeconds: 10
```

### 8.2 redis-sentinel ComponentDefinition

```yaml
spec:
  type: redis-sentinel
  engine:
    kind: redis-sentinel
    version: "7.2"
  contracts:
    credential:
      systemAccounts:
        - name: op-sentinel
          statements:
            create: "~* &* +@all"
            update: "~* &* +@all"
          passwordPolicy:
            generation: platform
    services:
      exports:
        - name: sentinel
          serviceSpec:
            type: ClusterIP
            ports:
              - name: sentinel
                port: 26379
                targetPort: sentinel
  env:
    - name: KODA_COMPONENT_NAME
      valueFrom:
        componentFieldRef:
          shortName: Required
    - name: KODA_APPLICATION_NAME
      valueFrom:
        applicationFieldRef:
          applicationName: Required
    - name: KODA_COMPONENT_POD_NAME
      valueFrom:
        componentFieldRef:
          podNames: Required
    - name: KODA_COMPONENT_POD_FQDNS
      valueFrom:
        componentFieldRef:
          podFQDNs: Required
    - name: KODA_REDIS_SERVER_POD_FQDNS
      valueFrom:
        componentFieldRef:
          componentName: redis-server
          podFQDNs: Required
    - name: OP_SENTINEL_PASSWORD
      valueFrom:
        credentialFieldRef:
          name: op-sentinel
          password: Required
    - name: SENTINEL_PORT
      value: "26379"
    - name: HOSTNAME
      valueFrom:
        fieldRef:
          fieldPath: metadata.name
    - name: POD_NAMESPACE
      valueFrom:
        fieldRef:
          fieldPath: metadata.namespace
  lifecycle:
    actions:
      postProvision:
        exec:
          command: ["/scripts/lifecycle.sh", "postProvision"]
        targetPodSelector: All
      accountProvision:
        exec:
          command: ["/scripts/lifecycle.sh", "accountProvision"]
        targetPodSelector: All
      roleProbe:
        exec:
          command: ["/scripts/lifecycle.sh", "roleProbe"]
        targetPodSelector: All
        initialDelaySeconds: 5
        periodSeconds: 10
      availableProbe:
        exec:
          command: ["/scripts/lifecycle.sh", "availableProbe"]
        targetPodSelector: All
        initialDelaySeconds: 5
        periodSeconds: 10
```

### 8.3 环境变量汇总表

| 变量名 | 组件 | 来源 | 必填 | 用途 |
|---|---|---|---|---|
| `KODA_COMPONENT_NAME` | all | `componentFieldRef.shortName` | 是 | 组件短名：`redis-server` / `sentinel` / `redis-exporter` |
| `KODA_APPLICATION_NAME` | all | `applicationFieldRef.applicationName` | 是 | Sentinel master-name 前缀 |
| `KODA_COMPONENT_POD_NAME` | all | `componentFieldRef.podNames` | 是 | 当前组件 Pod 名列表 |
| `KODA_COMPONENT_POD_FQDNS` | all | `componentFieldRef.podFQDNs` | 是 | 当前组件 Pod FQDN 列表 |
| `KODA_REDIS_SERVER_POD_FQDNS` | sentinel | `componentFieldRef(redis-server).podFQDNs` | 是 | Sentinel 监控的 Redis Server Pod FQDN |
| `OP_REPLICA_PASSWORD` | redis-server | `credentialFieldRef(op-replica).password` | 是 | Redis 运维账号密码 |
| `OP_SENTINEL_PASSWORD` | redis-sentinel | `credentialFieldRef(op-sentinel).password` | 是 | Sentinel 运维账号密码 |
| `REDIS_PORT` | redis-server | 固定值 | 是 | Redis 监听端口 |
| `SENTINEL_PORT` | sentinel | 固定值 | 是 | Sentinel 监听端口 |
| `HOSTNAME` | all | `fieldRef metadata.name` | 是 | Pod 名，用于 ordinal 推导 |
| `POD_NAMESPACE` | all | `fieldRef metadata.namespace` | 是 | Pod 命名空间 |
| `CURRENT_POD_IP` | all | `fieldRef status.podIP` | 否 | 当前 Pod IP |
| `CURRENT_POD_HOST_IP` | all | `fieldRef status.hostIP` | 否 | 当前节点 IP，HostNetwork 时使用 |
| `REDIS_HOST_NETWORK_PORT` | redis-server | `hostNetworkFieldRef` | 否 | HostNetwork 模式下主机端口 |
| `SENTINEL_HOST_NETWORK_PORT` | sentinel | `hostNetworkFieldRef` | 否 | HostNetwork 模式下主机端口 |

---

## 9. init.sh 适配设计

### 9.1 主要变更点

1. **移除 `derive_password()`**：密码由 Koda 注入，不再需要基于 `REDIS_CLUSTER_ID` 派生。
2. **移除 `REDIS_CLUSTER_ID` 依赖**：master-name 改为 `KODA_APPLICATION_NAME-master`。
3. **移除 `KODA_HEADLESS_SERVICE` 依赖**：通过 `KODA_COMPONENT_POD_FQDNS` 和 `HOSTNAME` 推导当前 Pod FQDN。
4. **新增从 Koda Secret 读取密码**：`OP_REPLICA_PASSWORD`、`OP_SENTINEL_PASSWORD`。
5. **保留 HostNetwork 回退**：`REDIS_HOST_NETWORK_PORT` / `SENTINEL_HOST_NETWORK_PORT` 仍可选。

### 9.2 新增/修改函数

```bash
# 从 comma-separated FQDN 列表中按当前 Pod ordinal 匹配自身 FQDN
get_pod_fqdn() {
  lookup_value_by_ordinal "$KODA_COMPONENT_POD_FQDNS" "$HOSTNAME"
}

# 获取初始 master FQDN（ordinal 0）
get_initial_master_fqdn() {
  local first_entry
  first_entry="${KODA_COMPONENT_POD_FQDNS%%,*}"
  printf '%s' "$first_entry"
}

# 对明文密码做 SHA-256，用于 ACL 文件
hash_password() {
  local plaintext="$1"
  printf '%s' "$plaintext" | sha256sum | awk '{print $1}'
}
```

### 9.3 resolve_announce_addr 函数

优先级保持不变：

1. HostNetwork 模式（如果 `REDIS_HOST_NETWORK_PORT` 非空）。
2. Headless Service FQDN 回退（通过 `get_pod_fqdn`）。

```bash
resolve_announce_addr() {
  redis_announce_ip=""
  redis_announce_port=""

  # 1. HostNetwork 模式
  if [[ -n "${REDIS_HOST_NETWORK_PORT:-}" ]]; then
    redis_announce_ip="${CURRENT_POD_HOST_IP:-${CURRENT_POD_IP:-}}"
    redis_announce_port="${REDIS_HOST_NETWORK_PORT}"
    if [[ -n "$redis_announce_ip" && -n "$redis_announce_port" ]]; then
      return 0
    fi
  fi

  # 2. Headless Service FQDN 回退
  redis_announce_ip=$(get_pod_fqdn)
  redis_announce_port="${REDIS_PORT}"
}
```

### 9.4 init_server 函数

```bash
init_server() {
  ensure_dir "$REDIS_DATA_DIR"
  ensure_dir "$LOG_DIR"

  local first_creation=false
  if [[ ! -e "$REDIS_RUNTIME_CONFIG" ]]; then
    first_creation=true
    cat > "$REDIS_RUNTIME_CONFIG" <<EOF
include ${REDIS_TEMPLATE_PATH}
include ${REDIS_ANNOUNCE_CONFIG}
dir ${REDIS_DATA_DIR}
aclfile ${REDIS_ACL_FILE}
masteruser op-replica
masterauth ${OP_REPLICA_PASSWORD}
EOF
  fi

  resolve_announce_addr
  write_announce_conf

  # Pod 重启后，通过 Sentinel 查询当前 master
  if [[ "$first_creation" == false ]]; then
    local sentinel_replicas
    sentinel_replicas=$(count_entries "$KODA_COMPONENT_POD_FQDNS")  # sentinel 自身数量
    if [[ "$sentinel_replicas" -gt 0 ]]; then
      local master_info
      if master_info=$(sentinel_master_addr); then
        local master_host master_port
        read -r master_host master_port <<< "$master_info"
        update_replicaof "$REDIS_RUNTIME_CONFIG" "$master_host" "$master_port"
      fi
    fi
  fi

  if [[ ! -e "$REDIS_ACL_FILE" ]]; then
    touch "$REDIS_ACL_FILE"
  fi

  ensure_acl_user "$REDIS_ACL_FILE" "op-replica" \
    "user op-replica on #$(hash_password "$OP_REPLICA_PASSWORD") ~* &* +@all"
  ensure_default_user "$REDIS_ACL_FILE"
}
```

### 9.5 init_sentinel 函数

```bash
init_sentinel() {
  ensure_dir "$LOG_DIR"

  if [[ ! -e "$SENTINEL_CONFIG" ]]; then
    cat > "$SENTINEL_CONFIG" <<EOF
port ${SENTINEL_PORT}
aclfile ${REDIS_ACL_FILE}
sentinel sentinel-user op-sentinel
sentinel sentinel-pass ${OP_SENTINEL_PASSWORD}
EOF
  fi

  if [[ ! -e "$REDIS_ACL_FILE" ]]; then
    touch "$REDIS_ACL_FILE"
  fi

  ensure_acl_user "$REDIS_ACL_FILE" "op-sentinel" \
    "user op-sentinel on #$(hash_password "$OP_SENTINEL_PASSWORD") ~* &* +@all"
  ensure_default_user "$REDIS_ACL_FILE"
}
```

### 9.6 sentinel_master_addr 函数

查询 Sentinel 获取当前 master 地址。Sentinel Pod FQDN 从 `KODA_COMPONENT_POD_FQDNS`（sentinel 自身）获取。

```bash
sentinel_master_addr() {
  local master_name="${KODA_APPLICATION_NAME}-master"
  local pass="$OP_SENTINEL_PASSWORD"
  local fqdn

  while IFS= read -r fqdn; do
    [[ -z "$fqdn" ]] && continue
    local output
    output=$(redis-cli -h "$fqdn" -p "$SENTINEL_PORT" --user op-sentinel \
      --pass "$pass" --no-auth-warning SENTINEL MASTER "$master_name" 2>/dev/null || true)

    if [[ -n "$output" && "$output" != *"ERR"* ]]; then
      local master_ip master_port
      master_ip=$(printf '%s' "$output" | awk '/^ip$/{getline; print; exit}' | tr -d '\r')
      master_port=$(printf '%s' "$output" | awk '/^port$/{getline; print; exit}' | tr -d '\r')
      if [[ -n "$master_ip" && -n "$master_port" ]]; then
        printf '%s %s' "$master_ip" "$master_port"
        return 0
      fi
    fi
  done <<< "$(split "$KODA_COMPONENT_POD_FQDNS" ",")"

  return 1
}
```

---

## 10. lifecycle.sh 适配设计

### 10.1 主要变更点

1. **postProvision**：使用 `KODA_APPLICATION_NAME` 作为 master-name；使用 `KODA_COMPONENT_POD_FQDNS` 第一个条目作为初始 master FQDN。
2. **accountProvision**：使用 `OP_REPLICA_PASSWORD` / `OP_SENTINEL_PASSWORD` 连接本地实例，不再派生密码。
3. **reconfigure**：保持不变，继续读取 `KODA_CONFIG_CHANGED_PARAMETERS`。

### 10.2 postProvision 设计

#### redis-server 分支

```text
ordinal = ${HOSTNAME##*-}
master_name = "${KODA_APPLICATION_NAME}-master"
master_fqdn = 第一个 KODA_COMPONENT_POD_FQDNS 条目

if ordinal == 0:
    跳过 replicaof
else:
    使用 op-replica 用户连接本地 Redis
    执行 REPLICAOF ${master_fqdn} ${REDIS_PORT}
```

#### redis-sentinel 分支

```text
master_name = "${KODA_APPLICATION_NAME}-master"
master_fqdn = 第一个 KODA_REDIS_SERVER_POD_FQDNS 条目
quorum = (sentinel_replicas / 2) + 1

使用 op-sentinel 用户连接本地 Sentinel
if SENTINEL MASTER ${master_name} 不存在:
    执行 SENTINEL MONITOR ${master_name} ${master_fqdn} ${REDIS_PORT} ${quorum}
执行 SENTINEL SET ${master_name} auth-user op-replica
执行 SENTINEL SET ${master_name} auth-pass ${OP_REPLICA_PASSWORD}
```

### 10.3 accountProvision 设计

accountProvision 动作由 Koda 触发，环境变量 `KODA_ACCOUNT_NAME`、`KODA_ACCOUNT_PASSWORD`、`KODA_ACCOUNT_STATEMENT` 由 agent 注入。脚本无需关心密码来源。

连接本地实例时，根据 `KODA_COMPONENT_NAME` 选择：

| 组件 | 端口 | 用户 | 密码来源 |
|---|---|---|---|
| redis-server | `REDIS_PORT` | `op-replica` | `OP_REPLICA_PASSWORD` |
| sentinel | `SENTINEL_PORT` | `op-sentinel` | `OP_SENTINEL_PASSWORD` |

### 10.4 roleProbe / availableProbe

保持不变，但连接时使用 Koda 注入的密码。

---

## 11. ApplicationDefinition 设计

```yaml
apiVersion: definitions.koda.io/v1alpha1
kind: ApplicationDefinition
metadata:
  name: redis
spec:
  topologies:
    - name: replication-sentinel
      description: Redis replication with Sentinel for high availability
      components:
        - name: redis-server
          componentDef: redis-server
        - name: redis-sentinel
          componentDef: redis-sentinel
        - name: redis-exporter
          componentDef: redis-exporter
      assembly:
        provision:
          - redis-server
          - redis-sentinel
          - redis-exporter
```

---

## 12. ComponentMatrix 设计

```yaml
apiVersion: definitions.koda.io/v1alpha1
kind: ComponentMatrix
metadata:
  name: redis-7
spec:
  compatibilityRules:
    - compDefs:
        - redis-server
        - redis-sentinel
        - redis-exporter
      releases:
        - 7.2.4-v1.0.0
  releases:
    - name: 7.2.4-v1.0.0
      engineVersion: "7.2.4"
      images:
        redis-server: redis:7.2.4
        redis-sentinel: redis:7.2.4
        redis-exporter: oliver006/redis_exporter:v1.55.0
```

---

## 13. 风险与回退策略

### 13.1 风险：Pod FQDN 顺序与角色不一致

`componentFieldRef.podFQDNs` 返回按 Pod 名排序的列表。初始化时 ordinal 0 是 master，但 failover 后可能不是。

**回退**：
- postProvision 只在初始化时执行，使用第一个 FQDN 作为初始 master 是合理的。
- Pod 重启后，init.sh 通过 `sentinel_master_addr()` 查询 Sentinel 获取当前 master，而不是依赖第一个 FQDN。

### 13.2 风险：CredentialFieldRef 在 Definition env 中的限制

`resolvedDefinitionEnv`（`env_projection.go:840-848`）仅支持 `CredentialFieldRef`。但 `BuildDefinitionEnvRuntime`（`env_projection.go:63-124`）使用 `resolveDefinitionEnvRuntimeValue`，支持所有源类型。因此 `componentFieldRef` 等可以正常使用。

### 13.3 风险：master-name 唯一性

使用 `KODA_APPLICATION_NAME-master` 假设一个 Application 只有一个 Redis 集群。若未来扩展，需引入实例名。

### 13.4 风险：podService 未实现

外部访问仍受限。第一阶段通过 Headless FQDN 或 HostNetwork 解决；per-pod NodePort/LB 需等待 Koda 支持 `podService`。

### 13.5 回退：保留旧契约开关（可选）

如果新契约在过渡期需要兼容旧脚本，可以在 init.sh 中增加 fallback：

```bash
KODA_APPLICATION_NAME="${KODA_APPLICATION_NAME:-${REDIS_CLUSTER_ID}}"
OP_REPLICA_PASSWORD="${OP_REPLICA_PASSWORD:-$(derive_password_plaintext op-replica)}"
```

但建议最终只保留新契约，避免维护两套逻辑。

---

## 14. 实施顺序建议

1. **修改 ComponentDefinition 模板**：添加 `systemAccounts`、`env` 新变量、`lifecycle.actions`。
2. **修改 init.sh**：移除 `REDIS_CLUSTER_ID`、Headless Service 硬编码，使用 Koda 注入的密码和 Pod FQDN。
3. **修改 lifecycle.sh / actions/**：postProvision 使用新变量，accountProvision 使用 Koda 密码。
4. **更新单元测试**：覆盖新 env 契约和密码哈希逻辑。
5. **Chart 渲染验证**：确认 `helm template` 输出符合 Koda CRD 结构。
6. **Koda 平台联调**：验证安装、启动、failover、reconfigure 流程。

---

## 15. 结论

本设计通过 Koda 原生能力替代了 koda-apppack 中的自定义约定：

- 系统账号由 Koda 生成密码，通过 `CredentialFieldRef` 注入。
- 组件身份通过 `componentFieldRef.shortName` 获取。
- Pod 发现通过 `componentFieldRef.podFQDNs` 完成。
- Sentinel master-name 通过 `applicationFieldRef.applicationName` 构建。

该契约使 Redis AppPack 与 Koda 控制面更加解耦，去掉了 `REDIS_CLUSTER_ID`、`KODA_HEADLESS_SERVICE` 等非标准变量，为后续支持 `podService` 和更复杂的拓扑打下统一基础。
