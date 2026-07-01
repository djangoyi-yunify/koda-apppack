# Koda 项目 StatefulGroup 与 StatefulInstance API 宏观作用调研

> 调研范围：`/root/.local/share/opencode/repos/github.com/kubesphere-extensions/koda`
> 版本：`runtime.koda.io/v1alpha1`
> 日期：2026-06-30

## 1. 概述

`StatefulGroup` 与 `StatefulInstance` 是 Koda 平台运行有状态工作负载（数据库、中间件等）的核心运行时 API。二者共同承担了传统 Kubernetes `StatefulSet` 的角色，但采用了“组级抽象 + 实例级边界”的双层设计，以支持更复杂的运维语义，如角色感知更新、quorum 保护、实例级 OpsTask、辅助对象作用域等。

两条 API 同属一个 API Group：

- **Group**：`runtime.koda.io`
- **Version**：`v1alpha1`
- **Scope**：Namespaced

它们在整体控制链中的位置如下：

```text
Application -> Component -> StatefulGroup -> StatefulInstance -> Pod / PVC / Service / ConfigMap / Secret / SA / Role / RoleBinding
```

## 2. 分层职责

| 层级 | 核心资源 | 职责 |
|---|---|---|
| 定义层 | `ApplicationDefinition`、`ComponentDefinition`、`Component` | 描述“要运行什么数据库/中间件”，包括版本、配置、拓扑等 |
| 运行时组层 | `StatefulGroup` | 描述“组应该长什么样”：副本数、模板、更新策略、共享服务 |
| 运行时实例层 | `StatefulInstance` | 描述“单个实例如何落地”：Pod、PVC、辅助对象、生命周期、状态上报 |
| Kubernetes 原生层 | Pod / PVC / Service 等 | 最终被调度的实际工作负载 |

## 3. StatefulGroup：组级运行时抽象

### 3.1 定位

`StatefulGroup` 是 Koda 有状态负载的**组级入口**。它接收来自 `Component` 的运行时意图，并将其拆分为一组 `StatefulInstance`，同时维护组级共享资源和聚合状态。

### 3.2 关键 Spec 字段

| 字段 | 作用 |
|---|---|
| `replicas` | 总副本数 |
| `selector` | 实例选择器 |
| `template` | 默认 Pod 模板 |
| `volumeClaimTemplates` | 默认 PVC 模板 |
| `instanceTemplates` | 命名子模板，可指定独立副本、ordinal、模板、PVC |
| `ordinals` | 离散或区间 ordinal 分配 |
| `offline` / `stop` | 离线/停止语义 |
| `updateStrategy` | 更新策略：`RollingUpdate` / `OnDelete`，顺序：`Serial` / `Parallel` / `BestEffortParallel` |
| `podManagement` | Pod 管理策略：`OrderedReady` / `Parallel`，in-place / recreate 偏好 |
| `roles` | 角色定义，用于角色感知更新 |
| `availability` | 可用性门控，支持角色或探针表达式 |
| `persistentVolumeClaimRetentionPolicy` | PVC 保留策略：`Retain` / `Delete` |
| `auxiliaryObjects` | 引用的辅助对象（Service、ConfigMap、Secret、SA、Role、RoleBinding） |

### 3.3 控制器职责

`StatefulGroupReconciler` 主要负责：

1. **维护组级 headless Service**：名为 `<statefulgroup-name>-headless`，用于实例间发现。
2. **计算期望实例集合**：根据 `replicas`、`instanceTemplates`、`ordinals`、`offline` 等生成应存在的 `StatefulInstance` 列表。
3. **创建/更新/删除 StatefulInstance**：通过 `statefulgroupruntime.DesiredStatefulInstances` 计算差异并应用。
4. **规划组级更新**：`PlanStatefulInstanceUpdates` 决定哪些实例可以安全推进到新的 revision。
5. **聚合实例状态**：从所有 `StatefulInstance.status` 汇总出 `replicas`、`readyReplicas`、`currentRevision`、`updateRevision`、`status.instances[]` 等。
6. **处理角色与可用性**：结合 `roles` 与 `availability` 评估是否允许继续更新。

### 3.4 Watch 与所有权

```go
For(&runtimev1alpha1.StatefulGroup{}).
Owns(&corev1.Service{}).
Owns(&runtimev1alpha1.StatefulInstance{}).
```

`StatefulGroup` 不直接 watch Pod/PVC，而是通过 own `StatefulInstance` 间接感知实例变化。

## 4. StatefulInstance：单实例运行时边界

### 4.1 定位

`StatefulInstance` 是 Koda 有状态负载的**单实例运行时边界**。每个 `StatefulInstance` 对应一个稳定的实例身份（ordinal + templateName），并物化为一组 Kubernetes 原生资源。

### 4.2 关键 Spec 字段

| 字段 | 作用 |
|---|---|
| `statefulGroupRef` | 指向父级 `StatefulGroup`（必填） |
| `ordinal` | 实例 ordinal（必填） |
| `templateName` | 来源的命名模板 |
| `selector` | 实例选择器 |
| `podTemplate` | 该实例的 Pod 模板 |
| `volumeClaimTemplates` | 该实例的 PVC 模板 |
| `updatePolicy` / `upgradePolicy` | 更新策略：`StrictInPlace` / `PreferInPlace` / `ReCreate` |
| `stop` / `offline` | 停止/离线标志 |
| `auxiliaryObjects` | 实例级或共享辅助对象 |
| `persistentVolumeClaimRetentionPolicy` | PVC 保留策略 |

### 4.3 控制器职责

`StatefulInstanceReconciler` 主要负责：

1. **管理实例级最终器**：`runtime.koda.io/statefulinstance-protection`。
2. **协调辅助对象**：创建/更新/清理 `Shared` 或 `Instance` 作用域的 Service、ConfigMap、Secret、ServiceAccount、Role、RoleBinding。
3. **协调 PVC**：创建或仅 patch metadata。
4. **协调 Pod**：创建、in-place patch、resize 子资源或 recreate。
5. **应用运行配置**：通过 koda-agent 执行 `configReconfigure`、restart、`reloadThenRestart` 等动作。
6. **上报实例状态**：`phase`、`ready`、`available`、`role`、`currentRevision`、`updateRevision`、`conditions` 等。

### 4.4 Watch 与所有权

```go
For(&runtimev1alpha1.StatefulInstance{}).
Owns(&corev1.Pod{}).
Owns(&corev1.PersistentVolumeClaim{}).
Owns(&corev1.ConfigMap{}).
Owns(&corev1.Secret{}).
Owns(&corev1.ServiceAccount{}).
Owns(&corev1.Service{}).
Owns(&rbacv1.Role{}).
Owns(&rbacv1.RoleBinding{}).
```

`StatefulInstance` 直接持有并 watch 实例级别的所有原生资源。

## 5. 协作关系

### 5.1 控制流

```text
StatefulGroup
    |
    | 计算期望实例
    v
StatefulInstance 1  --> Pod + PVC + 辅助对象
StatefulInstance 2  --> Pod + PVC + 辅助对象
StatefulInstance N  --> Pod + PVC + 辅助对象
```

### 5.2 数据流

```text
Pod --> StatefulInstance.status --> StatefulGroup.status
```

`StatefulGroup` 不直接读取 Pod，而是通过 `StatefulInstance.status` 间接聚合，这使得组级控制器可以专注于“策略”，实例级控制器专注于“物化”。

### 5.3 设计收益

| 收益 | 说明 |
|---|---|
| 解耦 | `StatefulGroup` 不必关心单 Pod/PVC 的细节 |
| 显式身份 | 每个实例都有独立 CR，便于审计和运维 |
| 独立协调 | 实例级变更不会影响组级决策的稳定性 |
| 支持复杂语义 | 角色感知更新、quorum 保护、实例级 OpsTask 等 |
| 可扩展性 | 未来可在 `StatefulInstance` 上叠加更多运维动作 |

## 6. 关键文件索引

### 6.1 API 定义

| 资源 | 文件 |
|---|---|
| `StatefulGroup` | `api/runtime/v1alpha1/statefulgroup_types.go` |
| `StatefulInstance` | `api/runtime/v1alpha1/statefulinstance_types.go` |
| GroupVersionInfo | `api/runtime/v1alpha1/groupversion_info.go` |
| Webhook | `api/runtime/v1alpha1/statefulgroup_webhook.go`、`statefulinstance_webhook.go` |

### 6.2 控制器

| 控制器 | 文件 |
|---|---|
| `StatefulGroupReconciler` | `internal/controller/runtime/statefulgroup_controller.go` |
| `StatefulInstanceReconciler` | `internal/controller/runtime/statefulinstance_controller.go` |
| 实例生成 | `internal/controller/runtime/statefulgroup/statefulinstances.go` |
| 组级更新计划 | `internal/controller/runtime/statefulgroup/update.go` |
| 组级状态聚合 | `internal/controller/runtime/statefulgroup/status.go` |
| 实例对象构建 | `internal/controller/runtime/statefulinstance/objects.go` |
| 实例更新决策 | `internal/controller/runtime/statefulinstance/update.go` |
| 实例辅助对象 | `internal/controller/runtime/statefulinstance/auxiliary.go` |

### 6.3 CRD

| 资源 | 文件 |
|---|---|
| `StatefulGroup` | `config/crd/bases/runtime.koda.io_statefulgroups.yaml` |
| `StatefulInstance` | `config/crd/bases/runtime.koda.io_statefulinstances.yaml` |

### 6.4 设计文档

| 文档 | 主题 |
|---|---|
| `docs/superpowers/specs/2026-06-02-statefulgroup-api-contract-design.md` | StatefulGroup API 契约设计 |
| `docs/superpowers/specs/2026-06-03-statefulgroup-controller-skeleton-design.md` | StatefulGroup 控制器骨架 |
| `docs/superpowers/specs/2026-06-09-statefulinstance-runtime-design.md` | StatefulInstance 运行时设计 |
| `docs/superpowers/specs/2026-06-10-statefulinstance-auxiliary-lifecycle-design.md` | 辅助对象生命周期 |
| `docs/superpowers/specs/2026-06-16-statefulgroup-role-aware-update-plan-design.md` | 角色感知更新计划 |

## 7. 总结

`StatefulGroup` 与 `StatefulInstance` 构成了 Koda 有状态运行时层的核心双层架构：

- **StatefulGroup** 负责“组形态”：副本、模板、更新策略、共享 Service、状态聚合。
- **StatefulInstance** 负责“单个实例”：Pod、PVC、辅助对象、生命周期、运行配置应用、状态上报。

这种拆分借鉴了 KubeBlocks `InstanceSet` 的思想，但采用了 Koda 自身的命名与所有权语义，使得平台能够在定义层与 Kubernetes 原生资源之间，插入一个显式、稳定、可扩展的运行时抽象层。
