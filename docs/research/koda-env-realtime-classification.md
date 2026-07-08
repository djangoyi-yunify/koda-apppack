# Koda Pod 环境变量实时性分类（脚本视角）

## 核心结论

Pod 内脚本可见的环境变量只有两类：

- **非实时**：通过 `ComponentDefinition.spec.env`、`podSpec.containers[].env` 以及各类 `*FieldRef` 投影到 Pod 的环境变量。它们在 **Pod 创建时由 kubelet 注入**；只要 Pod 不重建，运行期间不会更新。
- **实时**：koda-agent 在执行 lifecycle action 时，通过 `ActionRequest.Parameters` 动态注入到进程中的环境变量。每次动作调用都会重新生成并注入。

> 本文只讨论脚本直接通过 `env` 读取的信息，不涉及脚本主动查询外部系统（如 DNS、K8s API）的能力。

---

## 为什么所有投影 env 都是非实时

Koda 的 env 投影链路如下：

```text
ComponentDefinition.spec.env
        │
        ▼
resolveDefinitionEnvRuntimeValue()  ← reconcile 阶段
        │
        ├── configMapKeyRef
        ├── secretKeyRef
        ├── applicationFieldRef
        ├── serviceFieldRef
        ├── serviceDependencyFieldRef
        ├── credentialFieldRef
        ├── tlsFieldRef
        ├── componentFieldRef
        ├── resourceFieldRef
        └── hostNetworkFieldRef
                    │
                    ▼
        BuildDefinitionEnvRuntime()
                    │
                    ├── Plain 值  ──────► 写入 ConfigMap，通过 envFrom 注入
                    └── ValueFrom 值 ───► 写入 PodSpec.Containers[*].Env
                    │
                    ▼
        applyDefinitionEnvRuntimeToPodTemplate()
                    │
                    ▼
              kubelet 创建容器
                    │
                    ▼
           环境变量正式固化进进程
```

关键点：

1. **解析发生在 reconcile 阶段**，不是 action 执行阶段。
2. **最终都变成 PodSpec 的一部分**（`containers[*].env` 或 `containers[*].envFrom`）。

因此，无论是 Koda 自定义的 `componentFieldRef`、`serviceFieldRef`，还是 K8s 原生的 `configMapKeyRef`、`secretKeyRef`、`fieldRef`、`resourceFieldRef`，**只要通过 `env` 或 `envFrom` 显式注入到容器中，在 Pod 不重建的情况下，脚本读到的值就不会改变**。

---

## 非实时 env 来源详细分类

### 1. 直接值（`value`）

| 来源 | 典型变量 | 说明 |
|---|---|---|
| `ComponentDefinition.spec.env[].value` | `KODA_COMPONENT_TYPE`、`REDIS_PORT` | 纯字符串，渲染后写入 ConfigMap 并通过 `envFrom` 注入 |
| `podSpec.containers[].env[].value` | `SENTINEL_PORT`、`REDIS_RUNTIME_CONFIG` | 原生 K8s env，直接写入容器 env |

### 2. ConfigMap / Secret

| 来源 | 实时性 | 说明 |
|---|---|---|
| `configMapKeyRef` | **否** | reconcile 时读取 ConfigMap key，值固化进 Pod |
| `secretKeyRef` | **否** | reconcile 时保留 SecretKeyRef，Secret 值在容器创建时解析 |

### 3. `applicationFieldRef`

| 字段 | 示例变量 | 实时性 | 说明 |
|---|---|---|---|
| `namespace` | `KODA_APP_NAMESPACE` | **否** | Component 所在 namespace |
| `applicationName` | `KODA_APP_NAME` | **否** | Application 名称 |
| `applicationUID` | `KODA_APP_UID` | **否** | Application UID |

### 4. `serviceFieldRef`

| 字段 | 示例变量 | 实时性 | 说明 |
|---|---|---|---|
| `host` | `KODA_HEADLESS_SERVICE` | **否（但稳定）** | 控制器拼接的 Service FQDN 字符串，通常不变 |
| `port.name` | `KODA_SERVICE_PORT_REDIS` | **否** | Service 端口数字，Service 端口变更后不会同步 |
| `serviceType` | `KODA_SERVICE_TYPE` | **否** | Service 类型 |
| `loadBalancer` | `KODA_SERVICE_LB` | **否** | LoadBalancer ingress，创建时读取 |

### 5. `serviceDependencyFieldRef`

| 字段 | 实时性 | 说明 |
|---|---|---|
| `endpoint` | **否** | 已解析依赖的 endpoint |
| `host` | **否** | 已解析依赖的 host |
| `port` | **否** | 已解析依赖的 port |
| `podFQDNs` | **否** | 已解析依赖的 Pod FQDN 列表 |
| `username` | **否** | 已解析依赖的用户名 |
| `password` | **否** | 已解析依赖的密码 |

### 6. `credentialFieldRef`

| 字段 | 实时性 | 说明 |
|---|---|---|
| `username` | **否** | credential 用户名 |
| `password` | **否** | credential 密码 |

### 7. `tlsFieldRef`

| 字段 | 示例变量 | 实时性 | 说明 |
|---|---|---|---|
| `enabled` | `KODA_TLS_ENABLED` | **否** | Component TLS 开关，创建时读取 |

### 8. `componentFieldRef`

| 字段 | 示例变量 | 实时性 | 说明 |
|---|---|---|---|
| `componentName` | `KODA_COMPONENT_NAME` | **否（稳定）** | Component 名称 |
| `shortName` | `KODA_COMPONENT_SHORT_NAME` | **否（稳定）** | Component short name |
| `replicas` | `KODA_COMPONENT_REPLICAS` | **否** | 创建时期望副本数 |
| `podNames` | `KODA_COMPONENT_POD_NAMES` | **否** | 创建时期望 Pod 名列表 |
| `podFQDNs` | `KODA_COMPONENT_POD_FQDNS` | **否** | 创建时期望 Pod FQDN 列表 |
| `engineVersion` | `KODA_ENGINE_VERSION` | **否（稳定）** | 引擎版本 |
| `podNamesForRole` | `KODA_LEADER_POD_NAMES` | **否** | 创建时某角色的 Pod 名列表 |
| `podFQDNsForRole` | `KODA_LEADER_POD_FQDNS` | **否** | 创建时某角色的 Pod FQDN 列表 |

### 9. `resourceFieldRef`

| 字段 | 示例变量 | 实时性 | 说明 |
|---|---|---|---|
| `cpu` | `KODA_CPU_REQUEST` | **否** | CPU request |
| `cpuLimit` | `KODA_CPU_LIMIT` | **否** | CPU limit |
| `memory` | `KODA_MEMORY_REQUEST` | **否** | Memory request |
| `memoryLimit` | `KODA_MEMORY_LIMIT` | **否** | Memory limit |
| `storage.name` | `KODA_STORAGE_DATA` | **否** | 指定存储的 request |

### 10. `hostNetworkFieldRef`

| 字段 | 实时性 | 说明 |
|---|---|---|
| `container.name` + `port.name` | **否** | 主机网络模式下分配的端口，创建时确定 |

### 11. K8s 原生 downward API（`podSpec.containers[].env` 中可用）

`podSpec` 使用原生 `corev1.PodSpec`，因此也可以写：

| 来源 | 实时性 | 说明 |
|---|---|---|
| `fieldRef` | **否** | kubelet 创建容器时解析，如 `metadata.name`、`status.podIP` |
| `resourceFieldRef` | **否** | kubelet 创建容器时解析资源请求/限制 |

---

## 非实时 env 不能作为参考依据的场景

非实时 env 的值等于 Pod 创建时刻的快照。只要 Pod 不重建，这些值就不会更新。因此，以下场景下不能把它们当作运行时的真实状态来使用。

### 扩缩容时 componentFieldRef 的偏差

**扩容（3 -> 5 节点）**：

| 节点 | `KODA_COMPONENT_REPLICAS` | `KODA_COMPONENT_POD_FQDNS` |
|---|---|---|
| `redis-server-0/1/2`（老节点） | 3 | 只有 3 个 FQDN |
| `redis-server-3/4`（新节点） | 5 | 5 个 FQDN |

老节点看不到新节点。

**缩容（5 -> 3 节点）**：

在 `memberLeave` 执行期间，所有节点 env 仍显示 5 个成员，包含即将被删除的节点。

### Service 端口变更

如果 `serviceFieldRef.port` 注入的端口后续被修改，已运行 Pod 的 env 不会同步。

### 角色 / Leader 变化

`componentFieldRef.podNamesForRole` / `podFQDNsForRole` 注入的是创建时刻某角色的 Pod 列表。角色发生漂移后，这些值会过时。

---

## 实时 env：lifecycle action 参数

koda-agent 在动作执行前，将 `ActionRequest.Parameters` 合并到进程 env 中，可以覆盖已有的非实时 env。这些参数每次动作调用都重新生成，因此是实时的。

### 当前已知的实时变量

| 变量 | 来源动作 | 说明 |
|---|---|---|
| `KODA_MEMBER_JOIN_POD_NAME` | `memberJoin` | 当前加入成员的 Pod 名 |
| `KODA_MEMBER_JOIN_POD_FQDN` | `memberJoin` | 当前加入成员的 Pod FQDN |
| `KODA_MEMBER_LEAVE_POD_NAME` | `memberLeave` | 当前离开成员的 Pod 名 |
| `KODA_MEMBER_LEAVE_POD_FQDN` | `memberLeave` | 当前离开成员的 Pod FQDN |
| `KODA_SWITCHOVER_SOURCE_NAME` | `switchover` | 切换源 Pod 名 |
| `KODA_SWITCHOVER_SOURCE_FQDN` | `switchover` | 切换源 Pod FQDN |
| `KODA_SWITCHOVER_ROLE` | `switchover` | 目标角色 |
| `KODA_SWITCHOVER_CANDIDATE_NAME` | `switchover` | 候选 Pod 名 |
| `KODA_SWITCHOVER_CANDIDATE_FQDN` | `switchover` | 候选 Pod FQDN |
| `KODA_CONFIG_NAME` | `reconfigure` | 配置名 |
| `KODA_CONFIG_MAP` | `reconfigure` | ConfigMap 名 |
| `KODA_CONFIG_HASH` | `reconfigure` | 配置哈希 |
| `KODA_CONFIG_REVISION` | `reconfigure` | 配置 revision |
| `KODA_CONFIG_FILES_CREATED` | `reconfigure` | 新增文件列表 |
| `KODA_CONFIG_FILES_UPDATED` | `reconfigure` | 更新文件列表 |
| `KODA_CONFIG_FILES_REMOVED` | `reconfigure` | 删除文件列表 |
| `KODA_CONFIG_CHANGED_PARAMETERS` | `reconfigure` | 变更参数列表 |
| `KODA_CONFIG_PARAM_<NAME>` | `reconfigure` | 单个变更参数 |
| `KODA_ACCOUNT_NAME` | `accountProvision` | 账号名 |
| `KODA_ACCOUNT_PASSWORD` | `accountProvision` | 账号密码 |
| `KODA_ACCOUNT_STATEMENT` | `accountProvision` | 执行的语句 |

---

## 使用原则速查

| 脚本需求 | env 能否提供 | 推荐来源 | 不推荐来源 |
|---|---|---|---|
| 读取静态配置（端口、组件类型） | 能 | `spec.env` / `podSpec.containers[].env` 直接值 | - |
| 构造稳定的 Service DNS 名 | 能 | `serviceFieldRef.host` | - |
| 判断自己是不是 ordinal 0 | 能 | `HOSTNAME`（K8s 注入） | - |
| 获取当前动作目标成员身份 | 能 | `KODA_MEMBER_JOIN_POD_FQDN` 等 action 参数 | - |
| 获取当前实际存活成员列表 | **不能** | - | `KODA_COMPONENT_POD_FQDNS` |
| 获取当前实际副本数 | **不能** | - | `KODA_COMPONENT_REPLICAS` |
| 获取变更前/后成员列表 | **不能** | - | `KODA_COMPONENT_POD_FQDNS` |
| 获取 leader / primary 列表 | **不能** | - | `KODA_LEADER_POD_FQDNS` |
| 获取当前账号密码 | 能（账号操作时） | `KODA_ACCOUNT_PASSWORD` | - |
| 获取本次配置变更参数 | 能 | `KODA_CONFIG_CHANGED_PARAMETERS` | - |

> env 无法覆盖的需求，必须通过平台能力增强或脚本外部查询机制解决，不在本文讨论范围。

---

## 参考文档

- `docs/research/koda-member-lifecycle-action-context-research.md`
- `docs/research/koda-port-and-headless-service-research.md`
- Koda 源码：`internal/controller/core/component/env_projection.go`
- Koda 源码：`internal/agent/runtime/action.go`
