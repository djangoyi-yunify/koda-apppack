# Koda Service 环境变量投影调研

本文聚焦 Koda 中与 Service 相关的环境变量投影细节，包括 `serviceFieldRef` 与 `serviceDependencyFieldRef`。关于投影机制、实时性、重启行为的通用结论，参见 `docs/research/koda-pod-env-projection-realtime-and-restart.md`。

---

## `serviceFieldRef.port.name` 示例

`serviceFieldRef.port.name` 按名称选中 Service 端口，注入的是该名称对应的**数字端口**。

假设 Service 端口定义为：

```yaml
spec:
  ports:
    - name: redis
      port: 6379
```

ComponentDefinition env 配置：

```yaml
spec:
  env:
    - name: KODA_SERVICE_PORT_REDIS
      valueFrom:
        serviceFieldRef:
          name: redis-service
          port:
            name: redis
```

注入到 Pod 里的值为 `6379`，而不是字符串 `redis`。

---

## 相关字段对应关系

`serviceFieldRef` 的解析涉及 **ComponentDefinition**、**Service** 和 **Pod env** 三类配置：

| `serviceFieldRef` 字段 | ComponentDefinition 对应字段 | Service 对应字段 | 含义 |
|---|---|---|---|
| `serviceFieldRef.name` | `spec.contracts.services.exports[].name` | 生成的 Service 名 | 定位 service export |
| `serviceFieldRef.port.name` | `exports[].serviceSpec.ports[].name` | `spec.ports[].name` | 按名称选择端口 |
| 注入 env 的值 | - | `spec.ports[].port` | 数字端口 |

---

## `exports` 与默认 Headless Service

`spec.contracts.services.exports` 是组件主动声明对外暴露的 Service 契约：

- Koda 据此创建 Service。
- `serviceFieldRef` 只能引用 exports 中声明的 service。
- 其他组件可通过 `serviceDependencyFieldRef` 依赖这些 service。

但还存在不在 `exports` 中的 Service，例如 **默认 Headless Service**（`<component-name>-headless`）。它是系统为 Pod DNS 发现自动创建的，**不能**通过 `serviceFieldRef` 引用。

---

## 实例级端口覆盖

ComponentDefinition 提供默认端口，但单个 Component 实例可通过 `spec.overrides.services` 覆盖。

ComponentDefinition：

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
```

Component 实例覆盖：

```yaml
spec:
  overrides:
    services:
      - name: redis-service
        serviceSpec:
          ports:
            - name: redis
              port: 6380
```

`overlayServiceSpec()` 会整体覆盖 `ports` 数组。未写覆盖的实例保持默认 `6379`。

---

## 修改 Service 端口是否会触发 Pod 重建

这里的“修改 Service”指修改 Component 实例中的 `spec.overrides.services`，它最终修改的是 K8s Service 对象。

仅修改 Service 时，**不会触发 Pod 重建**：

- 修改 Service `port`：`serviceFieldRef.port.name` 解析出的新值会写入 Koda 的 env ConfigMap（`<component-name>-env`），Pod 模板中只保留稳定的 ConfigMap 名称。`PodTemplateRevision` 仅对 Pod 模板做哈希，ConfigMap 内容变化不影响 revision，因此不会触发 StatefulGroup 滚动更新。
- 修改 Service `targetPort`：只更新 Service 对象，不会触发 Pod 重建。容器进程如果要监听新端口，必须另外修改 Pod template（如 `containerPort`、env、配置模板等），已超出“只修改 Service”的范畴。

> 不触发重建不等于值会实时更新。运行中的容器不会自动感知 `envFrom` 引用的 ConfigMap 内容变化；只有 Pod 重建后才会读到新端口。详见 `docs/research/koda-pod-env-projection-realtime-and-restart.md`。

---

## `serviceDependencyFieldRef`

`serviceDependencyFieldRef` 从声明的 service dependency 中解析已解析的连接信息。其字段含义与实时性结论与 `serviceFieldRef` 相同，参见 `docs/research/koda-pod-env-projection-realtime-and-restart.md`。

---

## 参考文档

- `docs/research/koda-pod-env-projection-realtime-and-restart.md`
- `docs/research/koda-port-and-headless-service-research.md`
- Koda 源码：`internal/controller/core/component/env_projection.go`
- Koda 源码：`internal/controller/core/component/service_builder.go`
- Koda 源码：`internal/controller/core/component/service_update.go`
