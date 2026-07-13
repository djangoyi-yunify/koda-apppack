# Koda 与 KubeBlocks Redis 服务宣告环境变量能力对比调研

## 1. 背景与目标

`docs/research/kubeblocks-addons-redis-service-announce-approach.md` 详细描述了 KubeBlocks 中 Redis 组件如何通过 Kubernetes Service、控制面环境变量与容器内脚本配合，实现外部可访问的复制拓扑：

- 容器内 Redis 进程固定监听 `6379`。
- 外部访问入口通过 Service（ClusterIP / NodePort / LoadBalancer / HostNetwork）提供。
- Redis 通过 `replica-announce-ip` 和 `replica-announce-port` 宣告自己的外部可访问地址。
- **控制面负责创建 Service、分配端口 / LB IP，并将运行时事实编码为环境变量**（如 `REDIS_ADVERTISED_PORT`、`REDIS_LB_ADVERTISED_HOST`、`REDIS_HOST_NETWORK_PORT`）。
- 容器内脚本解析环境变量，按 Pod ordinal 匹配当前 Pod 对应项，生成 `replica-announce-*` 配置。

本文聚焦回答：**Koda 控制面是否也提供类似的环境变量构建能力？** 如果有，能力边界在哪里；如果没有，差距是什么。

---

## 2. KubeBlocks Redis 关键机制回顾

### 2.1 per-pod Service 聚合环境变量

KubeBlocks 控制面在 `pkg/controller/component/vars.go` 中实现 `serviceVarRef`。当 Service 开启 `podService: true` 时，控制面会为每个 Pod 创建独立的 Service，并将所有 per-pod Service 的信息聚合成逗号分隔的 `svcName:value` 字符串：

```text
REDIS_ADVERTISED_PORT     = mycluster-redis-redis-advertised-0:30001,mycluster-redis-redis-advertised-1:30002,...
REDIS_LB_ADVERTISED_PORT  = mycluster-redis-redis-lb-advertised-0:6379,mycluster-redis-redis-lb-advertised-1:6379,...
REDIS_LB_ADVERTISED_HOST  = mycluster-redis-redis-lb-advertised-0:lb-0.example.com,mycluster-redis-redis-lb-advertised-1:lb-1.example.com,...
```

容器内脚本 `redis-start.sh` 通过 `extract_obj_ordinal()` 从 Pod 名和 Service 名中提取 ordinal，匹配当前 Pod 对应项，从而得到正确的 `replica-announce-ip/port`。

### 2.2 HostNetwork 端口注入

```text
REDIS_HOST_NETWORK_PORT = <allocated-port>
```

控制面为 HostNetwork 模式分配主机端口，并直接以单个数值注入。

### 2.3 NodePort 取值特殊性

KubeBlocks 的 `serviceVarRef.port` 在 NodePort 类型下会取 `spec.ports[].nodePort`，而不是 `spec.ports[].port`。

---

## 3. Koda 的 Service 环境变量投影能力

Koda 在 `ComponentDefinition.spec.env` 中支持类似的引用机制，字段名称与 KubeBlocks 不同：

| KubeBlocks | Koda |
|---|---|
| `vars[*].valueFrom.serviceVarRef` | `spec.env[*].valueFrom.serviceFieldRef` |
| `vars[*].valueFrom.hostNetworkVarRef` | `spec.env[*].valueFrom.hostNetworkFieldRef` |

控制面实现位于 `internal/controller/core/component/env_projection.go`。

### 3.1 `serviceFieldRef`

`resolveServiceFieldRuntimeValue` 支持从本组件暴露的 Service 中解析以下字段：

| 字段 | 含义 | 注入示例 |
|---|---|---|
| `serviceType` | Service 类型 | `ClusterIP`、`NodePort`、`LoadBalancer` |
| `host` | Service FQDN | `demo-db-client.default.svc.cluster.local` |
| `loadBalancer` | LoadBalancer Ingress IP/Hostname | `db.example.com` |
| `port` | 指定 name 的 Service 端口 | `5432` |

YAML 示例：

```yaml
spec:
  contracts:
    services:
      exports:
        - name: redis-advertised
          serviceSpec:
            type: NodePort
            ports:
              - name: redis
                port: 6379
  env:
    - name: REDIS_SERVICE_TYPE
      valueFrom:
        serviceFieldRef:
          name: redis-advertised
          serviceType: Required
    - name: REDIS_SERVICE_HOST
      valueFrom:
        serviceFieldRef:
          name: redis-advertised
          host: Required
    - name: REDIS_SERVICE_PORT
      valueFrom:
        serviceFieldRef:
          name: redis-advertised
          port:
            name: redis
            option: Required
```

### 3.2 `hostNetworkFieldRef`

`resolveHostNetworkFieldRuntimeValue` 从 `ctx.HostNetworkPorts` 中读取为当前 Pod 分配的主机端口：

```yaml
spec:
  env:
    - name: REDIS_HOST_NETWORK_PORT
      valueFrom:
        hostNetworkFieldRef:
          container:
            name: redis
            port:
              name: redis
              option: Required
```

这与 KubeBlocks 的 `REDIS_HOST_NETWORK_PORT` 能力等价。

---

## 4. 关键差异与 Gap 分析

### 4.1 不支持 per-pod Service 聚合

KubeBlocks Redis 方案的核心是**聚合所有 per-pod Service 的信息为逗号分隔字符串**，容器内脚本端再按 ordinal 匹配。Koda 的 `serviceFieldRef` 只解析**单个 Service** 的单一标量字段：

```go
serviceName := serviceGeneratedName(ctx.Component.Name, effective.serviceNameSegment)
```

生成的 Service 名格式为 `<component>-<serviceNameSegment>`，没有 `<component>-<serviceNameSegment>-<ordinal>` 的 per-pod 命名，也不会跨多个 Pod 聚合为 `svcName:value,svcName:value,...` 形式。

因此，Koda 目前无法直接产生类似 `REDIS_ADVERTISED_PORT = svc-0:30001,svc-1:30002` 的环境变量。

### 4.2 `port` 取值未区分 NodePort

KubeBlocks 的 `serviceVarRef.port` 在 NodePort 场景下取 `spec.ports[].nodePort`，而 Koda 的 `resolveServiceFieldRuntimeValue` 在 `port` 分支中：

```go
port, ok := selectServicePort(service, ref.Port.Name)
return plainRuntimeValue(envName, strconv.Itoa(int(port.Port))), true, nil
```

它始终取 `spec.ports[].port`，不取 `nodePort`。因此即使将来支持 per-pod Service，也无法直接复现 KubeBlocks Redis 的 NodePort 宣告行为。

### 4.3 `PodService` 尚未实际落地

Koda API 中已存在 `ComponentServiceExport.PodService` 字段：

```go
type ComponentServiceExport struct {
    Name        string
    ServiceName string
    ServiceSpec corev1.ServiceSpec
    RoleSelector string
    PodService bool
    Provisioning *ComponentServiceProvisioning
}
```

但控制面 `BuildDesiredServices` 遇到 `PodService: true` 时，仅将其标记为 pending 并重新入队：

```go
if effective.podService {
    pending = append(pending, PendingServiceExport{
        Name:    export.Name,
        Reason:  serviceExportPendingReason,
        Message: fmt.Sprintf("service export %q is waiting for runtime pod identity facts", export.Name),
    })
    continue
}
```

即 **per-pod Service 的自动创建逻辑尚未实现**，对应的环境变量聚合链路也无从谈起。

### 4.4 容器内脚本侧缺少配套逻辑

KubeBlocks Redis 方案的另一关键是容器内脚本 `redis-start.sh` 中 `parse_redis_announce_addr()` 的 ordinal 匹配与优先级回退逻辑。Koda 目前没有对应组件定义或容器内脚本去消费这种聚合型环境变量。

---

## 5. 能力对照表

| 能力 | KubeBlocks Redis | Koda |
|---|---|---|
| 从本组件 Service 取 Type | `serviceVarRef.serviceType` | `serviceFieldRef.serviceType` ✅ |
| 从本组件 Service 取 Host/FQDN | `serviceVarRef.host` | `serviceFieldRef.host` ✅ |
| 从本组件 Service 取 LB Ingress | `serviceVarRef.loadBalancer` | `serviceFieldRef.loadBalancer` ✅ |
| 从本组件 Service 取 Port（ClusterIP/LB） | `serviceVarRef.port` | `serviceFieldRef.port` ✅ |
| 从本组件 Service 取 Port（NodePort 取 nodePort） | `serviceVarRef.port` | `serviceFieldRef.port`（取 `spec.port`）⚠️ |
| 注入 HostNetwork 端口 | `hostNetworkVarRef` | `hostNetworkFieldRef` ✅ |
| per-pod Service 自动创建 | ✅ 已实现 | ❌ 仅标记 pending |
| 聚合所有 per-pod Service 为 `svcName:value,...` | ✅ 已实现 | ❌ 未实现 |
| 按 ordinal 匹配当前 Pod 的 advertise 项 | 容器内脚本侧实现 | 无对应控制面输出 |

---

## 6. 结论

**Koda 控制面已经具备单个 Service 维度的环境变量注入能力**（Service Type、FQDN、LB Ingress、端口、HostNetwork 端口），在概念上对应 KubeBlocks 的 `serviceVarRef` 与 `hostNetworkVarRef`。

针对 Redis 这种 **per-pod Service + 聚合所有 Pod 的 Service 信息为逗号分隔字符串** 的服务宣告环境变量构建能力，Koda **目前尚未实现**。差距主要体现在：

1. **per-pod Service 创建未落地**：`PodService: true` 仅被标记为 pending，未实际创建 Service。
2. **缺少聚合逻辑**：`serviceFieldRef` 只返回单个 Service 的标量值，不会生成 `svcName:value` 列表。
3. **NodePort 取值不一致**：`serviceFieldRef.port` 取 `spec.ports[].port`，不取 `nodePort`。
4. **缺少容器内脚本侧配套**：没有类似 `redis-start.sh` 的 ordinal 匹配与优先级回退逻辑。

### 6.1 当前设计选择

鉴于上述能力差距，Redis AppPack 在当前阶段采用以下策略：

- **默认回退到 Headless Service**：无外部 per-pod Service 时，`replica-announce-ip` 使用 Pod FQDN，`replica-announce-port` 使用容器端口 `6379`。
- **HostNetwork 作为立即可用的外部宣告方式**：启用 `hostNetwork` 时，通过 `hostNetworkFieldRef` 注入 `REDIS_HOST_NETWORK_PORT`，`replica-announce-ip` 使用节点 IP。
- **per-pod NodePort / LoadBalancer 作为未来能力**：脚本侧已预留 `REDIS_ADVERTISED_PORT`、`REDIS_LB_ADVERTISED_HOST`、`REDIS_LB_ADVERTISED_PORT` 的 ordinal 匹配逻辑，但完整 E2E 链路需等待 Koda 控制面支持 `PodService` 后才能落地。
- **共享 ClusterIP Service 不用于 replica-announce**：仅作为集群内客户端访问入口，避免多个副本宣告同一地址导致 Sentinel 拓扑混乱。

---

## 7. 建议

若要在 Koda 上完整复现 KubeBlocks Redis 的服务宣告方案，需要补充以下能力：

1. **实现 per-pod Service 创建**：在 runtime 侧根据 `PodService` 契约，为每个 Pod 创建独立 Service（命名格式建议 `<component>-<serviceNameSegment>-<ordinal>`）。
2. **扩展环境变量聚合能力**：新增一种 env 来源（或扩展 `serviceFieldRef`），支持将所有 per-pod Service 的指定字段聚合为 `svcName:value,...` 字符串。
3. **支持 NodePort 取值**：在端口解析逻辑中，当 Service 类型为 NodePort 时返回 `nodePort`。
4. **提供容器内脚本适配示例**：参考 `redis-start.sh`，在 Koda 的组件容器内脚本中实现 ordinal 匹配与 `replica-announce-*` 生成。当前 `scripts/init.sh` 中的 `lookup_value_by_ordinal` 与 `resolve_announce_addr` 已可作为起点。

---

## 8. 参考

- `docs/research/kubeblocks-addons-redis-service-announce-approach.md`
- `docs/research/koda-env-service-projection.md`
- Koda 源码：`api/definitions/v1alpha1/definitions_types.go`
- Koda 源码：`internal/controller/core/component/env_projection.go`
- Koda 源码：`internal/controller/core/component/service_builder.go`
- Koda 源码：`internal/controller/core/component/context.go`
- Koda 源码：`internal/controller/core/component_controller.go`
