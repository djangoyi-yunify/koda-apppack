# Koda 端口与 Headless Service 机制调研

## 摘要

本文档基于 Koda 主仓库（`github.com/kubesphere-extensions/koda`）源码及其 MySQL E2E 测试，调研 Koda 平台如何为中间件工作负载生成 headless service、如何确定和同步端口，以及端口变更在现有机制下的可行路径与限制。调研结论对 Redis AppPack 中 `memberJoin`、`memberLeave`、服务发现及端口相关环境变量的设计具有直接参考价值。

---

## 1. 调研范围

- Koda 默认 headless service 的生成主体、命名规则与生命周期。
- Headless service 端口的来源与同步机制。
- Pod 稳定网络身份（FQDN）与 headless service 的绑定关系。
- 中间件容器端口在 `ComponentDefinition` / `ComponentParameter` / 生命周期脚本中的定位。
- 端口是否支持运行时可变，及其变更对已有实例的影响。

---

## 2. Headless Service 生成机制

### 2.1 生成主体

Koda 的 `StatefulGroup` 控制器在调和每个 `StatefulGroup` 时，会自动创建并管理一个默认 headless service。相关代码位于：

- `internal/controller/runtime/statefulgroup_controller.go`
- `internal/controller/runtime/statefulinstance/objects.go`
- `internal/controller/labels/labels.go`

```text
StatefulGroup controller reconcile()
  -> serviceName = HeadlessServiceName(statefulGroupName)
  -> create/patch Service(name=serviceName, ClusterIP=None, PublishNotReadyAddresses=true)
  -> Pod.Spec.Subdomain = serviceName
```

### 2.2 命名规则

```go
// internal/controller/labels/labels.go
func HeadlessServiceName(statefulGroupName string) string {
    return fmt.Sprintf("%s-headless", statefulGroupName)
}

// StatefulGroupName = ComponentName
// 例：ComponentName("demo", "redis") = "demo-redis"
// HeadlessServiceName("demo-redis") = "demo-redis-headless"
```

因此，Pod 的完整 FQDN 为：

```text
<pod-name>.<statefulgroup-name>-headless.<namespace>.svc.<cluster-domain>

# 示例
redis-server-1.demo-redis-headless.default.svc.cluster.local
```

该 FQDN 结构与 Kubernetes 原生 StatefulSet 的 headless service DNS 完全一致。

### 2.3 端口来源与同步

Headless service 的端口不是由 AppPack 单独声明一份 Service 定义，而是**从 Pod 模板中所有业务容器的 `containerPort` 自动收集**：

```go
// internal/controller/runtime/statefulgroup_controller.go
func servicePorts(template runtimev1alpha1.StatefulGroupPodTemplateSpec) []corev1.ServicePort {
    winners := map[portKey]corev1.ContainerPort{}
    for _, container := range template.Spec.Containers {
        for _, port := range container.Ports {
            if port.ContainerPort <= 0 {
                continue
            }
            key := portKey{protocol: port.Protocol, port: port.ContainerPort}
            if _, exists := winners[key]; !exists {
                winners[key] = port
            }
        }
    }
    // 转换为 ServicePort，targetPort = containerPort
}
```

关键行为：

- 只采集 `containerPort > 0` 的端口。
- 按 `(protocol, containerPort)` 去重，保留 first-seen 的端口名。
- 未命名端口按 `tcp-<port>` / `udp-<port>` 生成 service port 名。
- `targetPort` 固定为数字端口（`intstr.FromInt32(containerPort)`），不使用 named targetPort。

### 2.4 Pod Subdomain 绑定

`StatefulInstance` 在生成 Pod 时，将 `Pod.Spec.Subdomain` 设为默认 headless service 名：

```go
// internal/controller/runtime/statefulinstance/objects.go
func wireStableNetworkIdentity(podSpec *corev1.PodSpec, inst *runtimev1alpha1.StatefulInstance) {
    if podSpec.Subdomain == "" && inst.Spec.StatefulGroupRef != "" {
        podSpec.Subdomain = controllerlabels.HeadlessServiceName(inst.Spec.StatefulGroupRef)
    }
}
```

这保证了每个 Pod 拥有稳定的 DNS 身份，`memberJoin` 传入的 `KODA_MEMBER_JOIN_POD_FQDN` 也基于此结构生成。

---

## 3. 端口在 Koda 中的定位：静态契约

### 3.1 端口声明位置

中间件端口首先在 `ComponentDefinition.spec.runtime.workload.podSpec.containers[].ports` 中声明。例如 MySQL E2E：

```yaml
runtime:
  workload:
    podSpec:
      containers:
      - name: mysql
        image: mysql:8.0.44
        ports:
        - name: mysql
          containerPort: 3306
```

### 3.2 不允许通过 Component 运行时覆盖

查看 `ComponentOverrides`（`api/core/v1alpha1/core_types.go:99`）与 `ComponentWorkloadTemplate`（`api/core/v1alpha1/core_types.go:310`），可覆盖项包括：

- Metadata
- Resources
- Scheduling
- Env
- Volumes
- PodManagement
- Services
- Configs / VolumeClaims

**没有 `Ports` 或 `ContainerPorts` 字段**。因此用户无法通过 `Component.spec.overrides` 或工作负载模板在运行时变更容器端口。

### 3.3 配置文件中的端口值如何渲染

Koda 参数渲染引擎提供 `getPortByName` 模板函数（`internal/controller/parameters/render_template.go:116`），允许配置模板读取 PodSpec 中声明的端口：

```go
func getPortByName(container corev1.Container, name string) map[string]any {
    for _, port := range container.Ports {
        if port.Name == name {
            return map[string]any{
                "name":          port.Name,
                "containerPort": port.ContainerPort,
                "protocol":      port.Protocol,
            }
        }
    }
    return nil
}
```

示例（MySQL `my.cnf` 模板）：

```ini
[mysqld]
port={{ (getPortByName (index .podSpec.containers 0) "mysql").containerPort }}
```

该值来源于**静态声明的 `containerPort`**，渲染后写入 runtime ConfigMap。如果通过 `ComponentParameter` 把 `port` 参数改成其他值，只会修改配置文件，**不会同步到 K8s containerPort 和 service port**，三者将不一致。

---

## 4. MySQL E2E 实证

Koda 主仓库的 MySQL E2E 测试直接验证了上述结论。

### 4.1 端口完全固定

- `test/e2e/testdata/mysql-primary-secondary/componentdefinition.yaml:137`：`containerPort: 3306`
- `test/e2e/testdata/mysql-single-node/componentdefinition.yaml:103`：`containerPort: 3306`
- Service exports：`port: 3306`，`targetPort: mysql`
- 所有脚本硬编码 `-P3306` 和 `SOURCE_PORT=3306`。

### 4.2 ConfigFileDefinition 不允许 port 参数

`test/e2e/testdata/mysql-primary-secondary/configfiledefinition.yaml`：

```yaml
cueSchema: |
  #MySQLParameter: {
    max_connections?: string
    binlog_expire_logs_seconds?: string
  }
managedParams:
  reloadOnly:
  - max_connections
  - binlog_expire_logs_seconds
```

运行时可变的参数只有 `max_connections` 和 `binlog_expire_logs_seconds`，均通过 MySQL `SET GLOBAL` 热加载，不影响监听端口。

### 4.3 Service 端口作为环境变量投影

`test/e2e/testdata/controller-chain/componentdefinition.yaml:166` 展示了把 service 端口投影为 env 的写法：

```yaml
env:
- name: CHAIN_SERVICE_PORT
  valueFrom:
    serviceFieldRef:
      name: writer
      port:
        name: mysql
        option: Required
```

但请注意：这是**读取已静态定义的服务端口**，并非运行时可变。源头仍然是 `serviceSpec.ports[0].port: 3306`。

---

## 5. 对 Redis AppPack 的启示

基于以上调研，Redis AppPack 设计建议如下：

1. **Redis 与 Sentinel 端口作为定义层常量**
   - 在 `ComponentDefinition.spec.runtime.workload.podSpec.containers[].ports` 中声明：
     - `redis-server`：`6379`
     - `redis-sentinel`：`26379`
   - 通过 Helm values 暴露，便于安装时一次性指定。

2. **环境变量静态注入**
   - `REDIS_PORT`、`SENTINEL_PORT` 作为容器 env 默认值。
   - `KODA_HEADLESS_SERVICE` 通过 `serviceFieldRef.host` 从 headless service 导出动态解析。
   - 生命周期脚本（`postProvision`、`memberJoin` 等）从 env 读取端口，不硬编码数字。

3. **不要把端口纳入 ComponentParameter 管理**
   - `ConfigFileDefinition` 的 schema 不应包含 `port`。
   - 避免用户运行时将 Redis 监听端口改得与 `containerPort` / service port 不一致。

4. **memberJoin 脚本可依赖的变量**
   - 动作专属：`KODA_MEMBER_JOIN_POD_NAME`、`KODA_MEMBER_JOIN_POD_FQDN`
   - 静态工作负载 env：`KODA_COMPONENT_TYPE`、`REDIS_CLUSTER_ID`、`KODA_HEADLESS_SERVICE`、`REDIS_PORT`、`SENTINEL_PORT`、`HOSTNAME`

---

## 6. 已知瑕疵

当前 Koda 机制下，**端口属于定义层静态契约**。如果运维或用户希望修改端口（例如把 Redis 从 6379 改为 16379），可行路径只有：

1. 修改 AppPack Helm `values.yaml` 中的端口配置；
2. 重新渲染并应用 `ComponentDefinition`；
3. 由 `ComponentDefinition` 变化触发所有引用该定义的 `Component` / `StatefulGroup` 滚动更新，重建 Pod。

### 6.1 瑕疵影响

- **全局性**：`ComponentDefinition` 是集群级（Cluster-scoped）资源，一个 `ComponentDefinition` 可能被多个租户 `Application` / `Component` 引用。修改定义层端口会**同时影响所有已创建的中间件实例**。
- **非租户隔离**：无法让租户 A 的 Redis 用 6379，租户 B 的 Redis 用 16379，除非为他们分别准备不同的 `ComponentDefinition` 或 `ComponentMatrix` 版本。
- **变更成本高**：由于 `containerPort` 改不了，任何端口调整都必须重建 Pod，无法通过 `reconfigure` 热加载完成。
- **服务依赖断裂**：其他组件或外部客户端通过 service 端口访问该中间件；端口变更后，所有依赖方都需要同步更新连接串。

### 6.2 与“运行时配置参数”的对比

| 维度 | `max_connections` 这类参数 | `port` 这类参数 |
|---|---|---|
| 修改方式 | `ComponentParameter` | 修改 `ComponentDefinition` / Helm values |
| 生效路径 | 渲染 runtime ConfigMap + `CONFIG SET` / `SET GLOBAL` | 重建 Pod |
| 影响范围 | 单个 `Component` | 所有引用该 `ComponentDefinition` 的实例 |
| 租户隔离 | 是 | 否 |
| 是否需要服务发现更新 | 否 | 是 |

因此，在 Redis AppPack 的早期阶段，建议把端口视为平台约定，默认固定为 6379 / 26379，不在产品层面提供运行时可变的端口能力。若未来确实有强需求，需要单独设计租户级端口分配或版本化 `ComponentDefinition` 方案，而不是简单通过参数热加载实现。

---

## 7. 参考代码路径

- `internal/controller/labels/labels.go` — headless service 命名。
- `internal/controller/runtime/statefulgroup_controller.go` — headless service 创建与端口收集。
- `internal/controller/runtime/statefulinstance/objects.go` — Pod Subdomain 绑定。
- `internal/controller/core/component/service_builder.go` — service export 生成。
- `internal/controller/parameters/render_template.go` — `getPortByName` 模板函数。
- `test/e2e/testdata/mysql-primary-secondary/componentdefinition.yaml` — MySQL 端口固定示例。
- `test/e2e/testdata/mysql-primary-secondary/configfiledefinition.yaml` — 运行时可变参数白名单。
- `test/e2e/testdata/controller-chain/componentdefinition.yaml` — `serviceFieldRef.port` 环境变量投影示例。
