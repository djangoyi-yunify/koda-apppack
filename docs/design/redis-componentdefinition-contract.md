# Redis ComponentDefinition 契约设计

> 本文档定义 `redis-server` 组件在 `ComponentDefinition` 层面需要声明的容器环境变量与服务契约，用于支撑 `scripts/init.sh` 的服务宣告推导与生命周期脚本的网络发现。

---

## 1. 目标与范围

- 明确 `redis-server` 容器需要注入的环境变量及其来源。
- 声明共享 ClusterIP Service：仅用于集群内部客户端访问，不作为 `replica-announce-*` 来源。
- 预留 per-pod NodePort / LoadBalancer Service 契约，标注为 Koda 控制面当前 pending 能力。
- 为 `scripts/init.sh`、`scripts/lifecycle.sh` 与 Koda 控制面之间的接口提供单一来源的设计依据。

---

## 2. 容器环境变量

以下环境变量注入到 `redis-server` 组件的主容器与 init 容器（`init.sh` 同样依赖它们）。

### 2.1 固定与 Downward API 变量

| 变量名 | 来源 | 说明 |
|---|---|---|
| `REDIS_PORT` | 固定值 `6379` | Redis 监听端口，等于容器 `containerPort`。 |
| `REDIS_HOST_NETWORK_PORT` | `valueFrom.hostNetworkFieldRef` | HostNetwork 模式下分配给当前 Pod 的主机端口；未启用 HostNetwork 时为空。 |
| `CURRENT_POD_HOST_IP` | `valueFrom.fieldRef`（`status.hostIP`） | 当前 Pod 所在节点 IP，HostNetwork 模式或未来 NodePort 模式下用于 `replica-announce-ip`。 |
| `CURRENT_POD_IP` | `valueFrom.fieldRef`（`status.podIP`） | 当前 Pod IP，作为 `CURRENT_POD_HOST_IP` 的兜底。 |
| `HOSTNAME` | `valueFrom.fieldRef`（`metadata.name`） | Pod 名，如 `redis-server-0`。 |
| `POD_NAMESPACE` | `valueFrom.fieldRef`（`metadata.namespace`） | Pod 所在命名空间。 |

### 2.2 Headless Service 名称

| 变量名 | 来源 | 说明 |
|---|---|---|
| `KODA_HEADLESS_SERVICE` | 固定值或构造值 | `redis-server` 组件的 headless service 名。Koda 当前无直接字段引用该名称，可采用约定命名 `<componentName>-headless` 或等待 Koda 提供注入能力。 |
| `KODA_SENTINEL_HEADLESS_SERVICE` | 固定值或构造值 | `redis-sentinel` 组件的 headless service 名，用于 Pod 重建时 `init.sh` 查询当前 master。 |
| `KODA_SENTINEL_REPLICAS` | 固定值 | Sentinel 副本数；大于 0 表示启用 Sentinel，触发 `init.sh` 的 master 查询逻辑。 |

### 2.3 YAML 示例

```yaml
spec:
  env:
    - name: REDIS_PORT
      value: "6379"
    - name: REDIS_HOST_NETWORK_PORT
      valueFrom:
        hostNetworkFieldRef:
          container:
            name: redis
            port:
              name: redis
              option: Required
    - name: CURRENT_POD_HOST_IP
      valueFrom:
        fieldRef:
          fieldPath: status.hostIP
    - name: CURRENT_POD_IP
      valueFrom:
        fieldRef:
          fieldPath: status.podIP
    - name: HOSTNAME
      valueFrom:
        fieldRef:
          fieldPath: metadata.name
    - name: POD_NAMESPACE
      valueFrom:
        fieldRef:
          fieldPath: metadata.namespace
    - name: KODA_HEADLESS_SERVICE
      value: "redis-server-headless"
    - name: KODA_SENTINEL_HEADLESS_SERVICE
      value: "redis-sentinel-headless"
    - name: KODA_SENTINEL_REPLICAS
      value: "3"
```

---

## 3. 共享 ClusterIP Service

### 3.1 契约声明

```yaml
spec:
  contracts:
    services:
      exports:
        - name: redis
          serviceSpec:
            type: ClusterIP
            ports:
              - name: redis
                port: 6379
                targetPort: redis
```

### 3.2 使用约束

- 该 Service 仅用于**集群内部**客户端访问 Redis 服务。
- 客户端通过 ClusterIP + 端口访问时，由 kube-proxy 将流量负载均衡到后端 Pod。
- **该 Service 不能作为 `replica-announce-ip` / `replica-announce-port` 的来源**。共享地址会让多个 Pod 宣告同一个入口，导致 Sentinel 把该地址同时识别为 master 与 replica，破坏拓扑一致性。
- 当未配置任何 per-pod 外部 Service 时，`init.sh` 回退到 Headless Service 给出的 Pod FQDN + `REDIS_PORT`。

---

## 4. 可选 per-pod Service 导出

### 4.1 NodePort Service（未来能力）

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
                targetPort: redis
          podService: true
```

- **当前状态**：Koda 控制面遇到 `podService: true` 时仅将该 export 标记为 pending，不会实际创建 per-pod Service。
- **未来能力**：Koda 支持 `podService` 后，每个 Pod 将获得独立的 NodePort Service，命名形如 `redis-server-redis-advertised-0`。
- **配套环境变量**：控制面需将所有 per-pod Service 的 `svcName:nodePort` 聚合为 `REDIS_ADVERTISED_PORT` 注入容器。
- **`init.sh` 侧已就绪**：`resolve_announce_addr()` 中的 per-pod NodePort 分支可按 Pod ordinal 匹配并生成 `replica-announce-ip/port`。

### 4.2 LoadBalancer Service（未来能力）

```yaml
spec:
  contracts:
    services:
      exports:
        - name: redis-lb-advertised
          serviceSpec:
            type: LoadBalancer
            ports:
              - name: redis
                port: 6379
                targetPort: redis
          podService: true
```

- **当前状态**：与 NodePort 相同，受限于 `podService` 未落地。
- **未来能力**：每个 Pod 获得独立的 LoadBalancer Service 与 ingress 地址。
- **配套环境变量**：控制面需聚合 per-pod LB 信息为 `REDIS_LB_ADVERTISED_HOST` 与 `REDIS_LB_ADVERTISED_PORT`。
- **`init.sh` 侧已就绪**：`resolve_announce_addr()` 中的 per-pod LB 分支可按 ordinal 匹配 LB ingress host 与端口。

### 4.3 HostNetwork 模式

HostNetwork 是当前即可使用的外部宣告方式，无需 per-pod Service：

- 在 `ComponentDefinition` 的 workload 中启用 `hostNetwork: true`。
- Koda 通过 `hostNetworkFieldRef` 为每个 Pod 分配独立主机端口，注入 `REDIS_HOST_NETWORK_PORT`。
- `init.sh` 以 `CURRENT_POD_HOST_IP` 作为 `replica-announce-ip`，`REDIS_HOST_NETWORK_PORT` 作为 `replica-announce-port`。

---

## 5. 服务契约总览

| Service | 类型 | per-pod | 当前是否可用 | 用途 |
|---|---|---|---|---|
| `redis` | ClusterIP | 否 | 是 | 集群内客户端访问 |
| `redis-advertised` | NodePort | 是 | 否（`podService` pending） | 外部访问 + `replica-announce-*` |
| `redis-lb-advertised` | LoadBalancer | 是 | 否（`podService` pending） | 外部访问 + `replica-announce-*` |
| Headless | Headless | 是（按 Pod DNS） | 是 | 默认回退的 `replica-announce-*` 来源 |
| HostNetwork | - | 是（按节点端口） | 是 | 外部访问 + `replica-announce-*` |

---

## 6. 与生命周期脚本的协作

- `scripts/init.sh` 在 init 容器阶段消费上述环境变量，生成 `redis-announce.conf`。
- `scripts/lifecycle.sh postProvision` 继续依赖 `KODA_HEADLESS_SERVICE`、`HOSTNAME`、`KODA_SENTINEL_REPLICAS` 等变量建立复制与 Sentinel 监控。
- 未来 per-pod NodePort/LB 落地后，`ComponentDefinition` 只需追加对应 Service export 与配套 env 变量，无需修改脚本主流程。

---

## 7. 参考

- `docs/design/redis-init-script-design.md`
- `docs/design/redis-lifecycle-design.md`
- `docs/research/koda-vs-kubeblocks-redis-service-announce-env-var.md`
- `docs/research/koda-service-types-research.md`
- `docs/research/koda-env-service-projection.md`
