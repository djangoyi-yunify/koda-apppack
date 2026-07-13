# Koda 对 Redis AppPack 运行支持能力调研

> 调研目标：判断 Koda 控制面能否为 koda-apppack Redis 提供运行所需的全部能力。
> 调研范围：Koda 主项目 `/root/.local/share/opencode/repos/github.com/kubesphere-extensions/koda` 的 API、控制器与 Agent 实现。
> 中间件目标：Redis replication + Sentinel 拓扑。
> 文档性质：调研结论，为 koda-apppack 设计新契约提供依据。

---

## 1. 调研结论摘要

**总体判断：Koda 控制面能够支撑 koda-apppack Redis 第一阶段（replication + Sentinel、集群内访问）的运行，但存在少数需要 koda-apppack 自行绕开或妥协的能力缺口。**

- **完全支持**：AppPack Helm 安装、ComponentDefinition / ApplicationDefinition / ComponentMatrix 静态资产、StatefulGroup/StatefulInstance 运行时、生命周期动作（postProvision / accountProvision / preTerminate）、探针（roleProbe / availableProbe）、OpsTask（switchover / reconfigure / scaling / restart）、环境变量投影（fieldRef / componentFieldRef / serviceFieldRef / hostNetworkFieldRef / credentialFieldRef）。
- **部分支持 / 需适配**：系统账号密码可通过 `CredentialFieldRef` 注入 Pod，但 init.sh 需要在启动前读到密码；组件名、Pod FQDN 可通过 `componentFieldRef` 获取，但需正确处理跨组件引用。
- **不支持**：`podService`（per-pod NodePort / LoadBalancer Service）仅在代码中被标记为 `PendingServiceExport`，不会实际创建 per-pod Service。

---

## 2. Koda 架构与 Redis 需求映射

```
┌─────────────────────────────────────────────────────────────────┐
│                       Koda 控制面能力全景                        │
├─────────────────────────────────────────────────────────────────┤
│  AppPack 层                                                     │
│  - Helm install/upgrade/uninstall Job                           │
│  - defaultInstallValues、valuesMapping、selector 约束           │
│  - 深度校验、retry annotation                                   │
├─────────────────────────────────────────────────────────────────┤
│  定义资产层                                                     │
│  - ApplicationDefinition / ComponentDefinition                  │
│  - ComponentMatrix / ConfigFileDefinition                       │
├─────────────────────────────────────────────────────────────────┤
│  运行时层                                                       │
│  - StatefulGroup / StatefulInstance                             │
│  - 默认 Headless Service、PVC、ServiceAccount、RBAC             │
├─────────────────────────────────────────────────────────────────┤
│  Agent 执行层                                                   │
│  - koda-agent sidecar（exec / HTTP / gRPC）                     │
│  - lifecycle actions、probes、tasks                             │
├─────────────────────────────────────────────────────────────────┤
│  运维任务层                                                     │
│  - OpsTask：switchover、reconfigure、scaling、restart、rebuild  │
└─────────────────────────────────────────────────────────────────┘
```

Redis replication + Sentinel 的对应关系：

| Redis 需求 | 对应 Koda 能力 |
|---|---|
| 能力包安装 | `AppPack` + Helm Job |
| 拓扑与组件定义 | `ApplicationDefinition` + `ComponentDefinition` |
| 版本与镜像矩阵 | `ComponentMatrix` |
| 有状态工作负载 | `StatefulGroup` / `StatefulInstance` |
| 初始化（replicaof / sentinel monitor） | `lifecycle.actions.postProvision` |
| 系统账号创建 | `lifecycle.actions.accountProvision` + `CredentialFieldRef` |
| 角色与可用性探测 | `lifecycle.actions.roleProbe` / `availableProbe` |
| 主从切换 | `OpsTask` + `lifecycle.actions.switchover` |
| 配置热更新 | `ComponentParameter` + `OpsTask` reconfigure + `configReconfigure:<name>` |
| 服务发现 | 默认 Headless Service + `componentFieldRef.podFQDNs` |

---

## 3. 逐项能力判定

### 3.1 AppPack 安装机制

| 子项 | 支持情况 | 源码依据 |
|---|---|---|
| Helm Chart 安装 | ✅ 支持 | `internal/controller/apppack/apppack_controller.go` |
| 安装 Job 编排 | ✅ 支持 | `internal/controller/apppack/jobs/jobs.go` |
| 阶段流转 Disabled → Enabling → Enabled | ✅ 支持 | `apppack_controller.go:267-282` |
| 失败重试 | ✅ 支持 | `RetryAnnotation = "apppack.koda.io/retry"` |
| 卸载保护 | ✅ 支持 | 检查 `Application` / `Component` / `ComponentParameter` 引用 |
| valuesMapping | ✅ 支持 | `apppack_types.go:181-202` |
| defaultInstallValues | ✅ 支持 | `apppack_types.go:271-294` |

### 3.2 定义资产

| 子项 | 支持情况 | 源码依据 |
|---|---|---|
| ApplicationDefinition | ✅ 支持 | `api/definitions/v1alpha1/definitions_types.go:12-103` |
| ComponentDefinition | ✅ 支持 | `definitions_types.go:122-887` |
| ComponentMatrix | ✅ 支持 | `definitions_types.go:899-954` |
| ConfigFileDefinition | ✅ 支持 | `api/parameters/v1alpha1/configfiledefinition_types.go` |
| Webhook 校验 | ✅ 支持 | `internal/webhook/definitions/v1alpha1/` |

### 3.3 运行时 StatefulGroup / StatefulInstance

| 子项 | 支持情况 | 源码依据 |
|---|---|---|
| StatefulGroup 控制器 | ✅ 支持 | `internal/controller/runtime/statefulgroup_controller.go` |
| StatefulInstance 控制器 | ✅ 支持 | `internal/controller/runtime/statefulinstance_controller.go` |
| 默认 Headless Service | ✅ 支持 | `statefulgroup_controller.go:113`、命名规则 `<statefulGroupName>-headless` |
| Pod 名 / FQDN 生成 | ✅ 支持 | `labels.HeadlessServiceName`、`dns.ServiceFQDN` |
| PVC / 存储 | ✅ 支持 | `StatefulGroupSpec.VolumeClaimTemplates` |
| 角色探测 | ✅ 支持 | `probeevent_controller.go` + `parseProbeRoleOutput` |
| 可用性探测 | ✅ 支持 | `statefulgroup/availability.go`、`statefulinstance/status.go` |

### 3.4 Agent 与生命周期动作

koda-agent 在检测到 `ComponentDefinition` 声明了 lifecycle actions 时自动注入 Pod。

| 子项 | 支持情况 | 源码依据 |
|---|---|---|
| Agent 自动注入 | ✅ 支持 | `internal/controller/core/component/agent.go:51-75` |
| exec 动作 | ✅ 支持 | `internal/agent/runtime/action.go:669-751` |
| HTTP 动作 | ✅ 支持 | `action.go:326-369` |
| gRPC 动作 | ✅ 支持 | `action.go:401-450` |
| postProvision | ✅ 支持 | `component/lifecycle_hooks.go:68-112` |
| preTerminate | ✅ 支持 | `component/lifecycle_hooks.go:114-170` |
| accountProvision | ✅ 支持 | `component/account_provision.go:139-206` |
| roleProbe / availableProbe | ✅ 支持 | `agent.go:90-91`、`probeevent_controller.go` |
| switchover / memberJoin / memberLeave | ✅ 支持 | `agent.go:92-94`、动作由 OpsTask 触发 |
| reconfigure | ✅ 支持 | `agent.go:85`、config reconfigure 由 `ComponentParameter` 触发 |

### 3.5 OpsTask 运维任务

| 子项 | 支持情况 | 源码依据 |
|---|---|---|
| OpsTask 控制器 | ✅ 支持 | `internal/controller/operations/opstask_controller.go` |
| switchover | ✅ 支持 | `internal/controller/operations/switchover.go` |
| reconfigure | ✅ 支持 | `internal/controller/operations/reconfigure.go`、handler `reconfigure_handler.go` |
| horizontal scaling | ✅ 支持 | `internal/controller/operations/horizontal_scaling*.go` |
| vertical scaling | ✅ 支持 | `internal/controller/operations/vertical_scaling*.go` |
| restart / start / stop | ✅ 支持 | `restart_handler.go`、`start_stop_test.go` |
| rebuild instance | ✅ 支持 | `rebuild_instance*.go` |

### 3.6 环境变量投影

`ComponentDefinition.spec.env` 支持多种 `valueFrom` 源（`internal/controller/core/component/env_projection.go`）。

| 源类型 | 支持情况 | Redis 适用场景 |
|---|---|---|
| `fieldRef` | ✅ | HOSTNAME、POD_NAMESPACE、Pod IP、Host IP |
| `componentFieldRef.componentName` | ✅ | 完整组件名 |
| `componentFieldRef.shortName` | ✅ | slot 名：`redis-server` / `sentinel` |
| `componentFieldRef.replicas` | ✅ | Sentinel 副本数 |
| `componentFieldRef.podNames` | ✅ | 当前组件 Pod 列表 |
| `componentFieldRef.podFQDNs` | ✅ | 当前组件 Pod FQDN 列表 |
| `componentFieldRef.podFQDNsForRole` | ✅ | 按角色过滤的 FQDN |
| `applicationFieldRef.applicationName` | ✅ | 应用名，可用作 master-name 前缀 |
| `applicationFieldRef.applicationUID` | ✅ | 应用 UID |
| `serviceFieldRef.host` / `port` | ✅ | ClusterIP 服务地址 |
| `hostNetworkFieldRef` | ✅ | HostNetwork 模式下主机端口 |
| `credentialFieldRef.username` / `password` | ✅ | 系统账号密码注入 |

### 3.7 服务导出

| 子项 | 支持情况 | 源码依据 |
|---|---|---|
| ClusterIP Service | ✅ 支持 | `service_builder.go` |
| Headless Service | ✅ 自动创建 | `statefulgroup_controller.go` |
| NodePort Service | ✅ 支持声明 | `service_builder.go` |
| LoadBalancer Service | ✅ 支持声明 | `service_builder.go` |
| per-pod Service (`podService: true`) | ❌ 未实现 | `service_builder.go:48-55` 仅标记 pending |

---

## 4. 关键缺口与风险

### 4.1 `podService` 未实现（唯一真正的能力缺口）

`ComponentDefinition.contracts.services.exports` 中 `podService: true` 不会创建 per-pod Service，仅被记录为 `PendingServiceExport`。

**影响**：
- 无法为每个 Redis Pod 分配独立 NodePort / LoadBalancer 地址。
- `replica-announce-ip` / `replica-announce-port` 无法使用 per-pod NodePort/LB 模式。

**缓解**：
- 第一阶段使用 Headless Service FQDN 作为 replica 宣告地址。
- 如需外部访问，使用 HostNetwork 模式 + `hostNetworkFieldRef`。

### 4.2 环境变量命名需与 Koda 契约对齐

Koda 不会自动注入 `KODA_COMPONENT_TYPE`、`KODA_HEADLESS_SERVICE`、`REDIS_CLUSTER_ID` 等自定义变量。Redis 脚本要么使用 Koda 原生支持的变量名，要么在 ComponentDefinition 中显式声明。

### 4.3 系统账号密码的启动时序

`accountProvision` 动作在 Pod ready 后执行。但 Redis 启动时需要 `masterauth` 等认证信息。因此系统账号密码必须通过 `CredentialFieldRef` 在 Pod 启动前注入，而不能仅靠 `accountProvision` 运行时创建。

### 4.4 Headless Service 名称与组件名耦合

Koda 默认 Headless Service 名为 `<statefulGroupName>-headless`，而 `statefulGroupName = componentName = <appName>-<slotName>`。如果 Redis 脚本写死服务名，会与 Application 名耦合。

---

## 5. 建议的适配方向

基于 Koda 当前能力，建议 koda-apppack 采用以下契约设计：

1. **系统账号**：声明 `op-replica`、`op-sentinel` 为 `systemAccounts`，通过 `CredentialFieldRef` 注入密码，init.sh 直接使用。
2. **去掉 `REDIS_CLUSTER_ID`**：用 `applicationFieldRef.applicationName` 作为 Sentinel master-name 前缀。
3. **去掉 `KODA_HEADLESS_SERVICE`**：改用 `componentFieldRef.podFQDNs` 发现 Pod。
4. **组件标识**：用 `componentFieldRef.shortName` 获取 `redis-server` / `sentinel`。
5. **外部访问**：第一阶段使用 Headless FQDN，第二阶段等待 Koda 实现 `podService` 后再支持 per-pod NodePort/LB。

---

## 6. 参考源码位置

| 文件 | 说明 |
|---|---|
| `api/extensions/v1alpha1/apppack_types.go` | AppPack CRD 定义 |
| `api/definitions/v1alpha1/definitions_types.go` | ComponentDefinition / ApplicationDefinition / ComponentMatrix 定义 |
| `api/runtime/v1alpha1/statefulgroup_types.go` | StatefulGroup 定义 |
| `api/runtime/v1alpha1/statefulinstance_types.go` | StatefulInstance 定义 |
| `internal/controller/apppack/apppack_controller.go` | AppPack 安装控制器 |
| `internal/controller/core/component_controller.go` | Component 控制器 |
| `internal/controller/core/component/agent.go` | koda-agent 注入逻辑 |
| `internal/controller/core/component/lifecycle_hooks.go` | postProvision / preTerminate |
| `internal/controller/core/component/account_provision.go` | accountProvision |
| `internal/controller/core/component/env_projection.go` | 环境变量投影 |
| `internal/controller/core/component/service_builder.go` | Service 导出，含 podService 处理 |
| `internal/controller/operations/opstask_controller.go` | OpsTask 控制器 |
| `internal/controller/operations/switchover.go` | switchover |
| `internal/controller/operations/reconfigure.go` | reconfigure |
| `internal/agent/runtime/action.go` | Agent 动作执行 |
| `internal/agent/runtime/probe.go` | Agent 探针执行 |
| `internal/controller/runtime/probeevent_controller.go` | 探针事件处理 |
| `internal/controller/labels/labels.go` | Headless Service 命名规则 |

---

## 7. 结论

Koda 控制面为 Redis AppPack 提供了**完整的第一阶段运行能力**，包括安装、运行时、生命周期动作、探针、运维任务和大部分环境变量投影。唯一的实质性缺口是 `podService`（per-pod NodePort / LoadBalancer）。

koda-apppack 当前应聚焦于：
1. 补齐 Helm Chart 与静态定义资产。
2. 调整脚本与 ComponentDefinition，使用 Koda 原生支持的变量源（`componentFieldRef`、`credentialFieldRef`、`applicationFieldRef`）。
3. 明确外部访问策略：优先 Headless FQDN，可选 HostNetwork，per-pod Service 待 Koda 后续支持。
