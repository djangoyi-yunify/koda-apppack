# Koda Service 类型调研

## 结论

Koda 中的 Service 从管理主体和用途上，大致可分为两类：

1. **Component 导出的普通 Service**：由 `ComponentDefinition.spec.contracts.services.exports` 声明，Component 控制器负责创建和维护。
2. **StatefulGroup 默认生成的 Headless Service**：由 StatefulGroup 控制器自动创建，用于为 Pod 提供稳定 DNS 身份，无需在 `exports` 中声明。

这两类 Service 由不同控制器管理、生命周期不同、可被引用的方式也不同。下文给出源码层面的调研依据。

---

## 1. Component 导出的普通 Service

### 1.1 声明位置

在 `ComponentDefinition` 的服务契约中显式声明：

```yaml
spec:
  contracts:
    services:
      exports:
        - name: redis-service
          serviceSpec:
            ports:
              - name: redis
                port: 6379
                targetPort: 6379
```

对应 API 类型：`api/definitions/v1alpha1/definitions_types.go` 中的 `ComponentServiceExport`。

### 1.2 创建主体

由 **Component 控制器**通过 `internal/controller/core/component/service_builder.go` 中的 `BuildDesiredServices()` 生成：

- 读取 `ComponentDefinition` 的 `exports`；
- 合并 `Component.spec.overrides.services` 中的覆盖；
- 生成 K8s `Service` 对象；
- 命名规则为 `<component-name>-<serviceNameSegment>`，例如 `demo-redis-redis-service`。

### 1.3 关键特征

| 特征 | 说明 |
|---|---|
| 管理控制器 | Component 控制器 |
| 可被 `serviceFieldRef` 引用 | 是，仅限 exports 中声明的 service |
| 支持 Service 类型 | ClusterIP / NodePort / LoadBalancer 等 |
| 选择器 | 指向 Component 对应的 Pod 标签 |
| 生命周期 | 随 Component / export 声明变化而创建、更新、清理 |
| 清理方式 | `PruneServices()` 会删除不再出现在 desired 中的 export Service |

### 1.4 对默认 Headless Service 名的保护

代码中显式防止 export 生成的 Service 名与默认 Headless Service 名冲突：

```go
// internal/controller/core/component/service_builder.go:58
if generatedName == defaultHeadlessServiceName(ctx.Component) {
    continue
}
```

---

## 2. StatefulGroup 默认 Headless Service

### 2.1 创建主体

由 **StatefulGroup 控制器**自动创建，无需在 `ComponentDefinition` 的 `exports` 中声明。

代码位置：`internal/controller/runtime/statefulgroup_controller.go`

```go
serviceName := controllerlabels.HeadlessServiceName(obj.Name)
// 创建/patch Service(name=serviceName, ClusterIP=None, PublishNotReadyAddresses=true)
```

### 2.2 命名规则

```go
// internal/controller/labels/labels.go:50
func HeadlessServiceName(statefulGroupName string) string {
    return fmt.Sprintf("%s-headless", statefulGroupName)
}
```

例如 StatefulGroup 名为 `demo-redis`，则默认 Headless Service 名为 `demo-redis-headless`。

### 2.3 端口来源与自动设置

Headless Service 的端口**不是由用户声明**，而是从 Pod 模板中所有业务容器的 `containerPort` 自动收集：

```go
// internal/controller/runtime/statefulgroup_controller.go:609
func servicePorts(template runtimev1alpha1.StatefulGroupPodTemplateSpec) []corev1.ServicePort {
    winners := map[portKey]corev1.ContainerPort{}
    for _, container := range template.Spec.Containers {
        for _, port := range container.Ports {
            if port.ContainerPort <= 0 {
                continue
            }
            // ...
        }
    }

    ports = append(ports, corev1.ServicePort{
        Name:       name,
        Protocol:   key.protocol,
        Port:       key.port,                    // = containerPort
        TargetPort: intstr.FromInt32(key.port),  // = containerPort
    })
}
```

关键行为：

- `port` 和 `targetPort` 都自动设置为 `containerPort`；
- 只采集 `containerPort > 0` 的端口；
- 按 `(protocol, containerPort)` 去重，保留 first-seen 的端口名；
- 未命名端口按 `tcp-<port>` / `udp-<port>` 生成 service port 名；
- `targetPort` 固定为数字端口，不使用 named targetPort。

因此，用户无法在 Headless Service 层面单独覆盖 `port` 或 `targetPort`，它们完全由 Pod 模板中的 `containerPort` 推导而来。

### 2.4 与 Pod DNS 身份的绑定

`StatefulInstance` 生成 Pod 时，将 `Pod.Spec.Subdomain` 设为默认 Headless Service 名：

```go
// internal/controller/runtime/statefulinstance/objects.go:128
func wireStableNetworkIdentity(podSpec *corev1.PodSpec, inst *runtimev1alpha1.StatefulInstance) {
    if podSpec.Subdomain == "" && inst.Spec.StatefulGroupRef != "" {
        podSpec.Subdomain = controllerlabels.HeadlessServiceName(inst.Spec.StatefulGroupRef)
    }
}
```

Pod 完整 FQDN 为：

```text
<pod-name>.<statefulgroup-name>-headless.<namespace>.svc.<cluster-domain>
```

### 2.5 关键特征

| 特征 | 说明 |
|---|---|
| 管理控制器 | StatefulGroup 控制器 |
| 可被 `serviceFieldRef` 引用 | 否，因为它不在 `exports` 中 |
| Service 类型 | 固定为 `ClusterIP`，且 `ClusterIP: None` |
| `PublishNotReadyAddresses` | `true` |
| 用途 | Pod 稳定网络身份 / DNS 发现 |
| 生命周期 | 随 StatefulGroup 创建和销毁 |
| 端口来源 | 自动从 `containerPort` 收集，`port` = `targetPort` = `containerPort` |

---

## 3. 两类 Service 对比

| 维度 | Component 导出的普通 Service | 默认 Headless Service |
|---|---|---|
| 声明方式 | `ComponentDefinition.spec.contracts.services.exports` | 无需声明，StatefulGroup 自动创建 |
| 控制器 | Component 控制器 | StatefulGroup 控制器 |
| 命名 | `<component-name>-<export-name>` | `<statefulgroup-name>-headless` |
| `ClusterIP` | 可配置（默认 ClusterIP） | 固定 `None` |
| 端口来源 | 用户显式声明 | 从 `containerPort` 自动收集 |
| `port` / `targetPort` | 用户自定义 | 自动等于 `containerPort` |
| `serviceFieldRef` | 可引用 | 不可引用 |
| 主要用途 | 对外暴露服务、依赖连接 | Pod 稳定 DNS 身份发现 |
| 删除清理 | `PruneServices()` 按 export label 清理 | StatefulGroup 级联删除 |

---

## 4. 补充：另外两类特殊 Service

除上述两类常规分类外，源码中还涉及两种特殊形态：

### 4.1 PodService（每个 Pod 一个 Service）

`ComponentServiceExport` 支持 `podService: true`。开启后，Koda 会为每个 Pod 单独创建一个 Service，而不是一个 Service Selector 选中所有 Pod。这种 Service 需要等待运行时 Pod 身份事实，因此会进入 `PendingServiceExport` 状态。

### 4.2 External Service Dependency

`serviceDependencyFieldRef` 引用的不是 Koda 创建的 Service，而是外部已解析的连接信息（`ResolvedServiceDependency`），包括 endpoint、host、port、podFQDNs、username、password 等。它属于依赖解析层面，不是 Koda 创建的 K8s Service 对象。

---

## 5. 参考代码路径

- `internal/controller/core/component/service_builder.go` — 导出 Service 的构建逻辑
- `internal/controller/core/component/service_update.go` — 导出 Service 的 apply/prune
- `internal/controller/core/component/env_projection.go` — `serviceFieldRef` 解析，仅支持 exports
- `internal/controller/runtime/statefulgroup_controller.go` — 默认 Headless Service 创建与端口收集
- `internal/controller/runtime/statefulinstance/objects.go` — Pod `Subdomain` 绑定
- `internal/controller/labels/labels.go` — `HeadlessServiceName` 命名规则
- `api/definitions/v1alpha1/definitions_types.go` — `ComponentServiceExport` API 定义
