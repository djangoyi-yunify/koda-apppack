# Koda Service 环境变量投影调研

## 概述

本文聚焦 Koda 中与 Service 相关的环境变量投影机制，包括 `serviceFieldRef` 和 `serviceDependencyFieldRef`。关于这些 env 的实时性讨论，参见 `docs/research/koda-env-realtime-classification.md`。

---

## `serviceFieldRef`

`serviceFieldRef` 从 ComponentDefinition 声明的 service export 中解析值，最终写入 Pod env。

### 字段说明

| 字段 | 示例变量 | 说明 |
|---|---|---|
| `host` | `KODA_HEADLESS_SERVICE` | Service FQDN 字符串 |
| `port.name` | `KODA_SERVICE_PORT_REDIS` | 按 `name` 选中 Service 端口，注入的是该名称对应的数字端口 |
| `serviceType` | `KODA_SERVICE_TYPE` | Service 类型 |
| `loadBalancer` | `KODA_SERVICE_LB` | LoadBalancer ingress，创建时读取 |

### `port.name` 示例

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

仅修改 Service 时：

- 修改 Service `port`：如果 ComponentDefinition env 使用了 `serviceFieldRef.port.name`，解析出的 env 值会变化，写入 Pod template，从而触发 Pod 重建。
- 修改 Service `targetPort`：只更新 Service 对象，不会触发 Pod 重建。容器进程如果要监听新端口，必须另外修改 Pod template（如 `containerPort`、env、配置模板等），已超出“只修改 Service”的范畴。

因此，在“只从修改 Service 出发”的前提下，触发 Pod 重建的唯一路径是：`serviceFieldRef.port.name` 引用了该 Service `port`，且 `port` 发生了变化。

> 建议：为降低心智负担，配置 Service 端口时建议保持 `port` 与 `targetPort` 取值相同。这样修改客户端端口即同步修改容器监听端口，行为更直观。

---

## `serviceDependencyFieldRef`

`serviceDependencyFieldRef` 从声明的 service dependency 中解析已解析的连接信息。

| 字段 | 说明 |
|---|---|
| `endpoint` | 已解析依赖的 endpoint |
| `host` | 已解析依赖的 host |
| `port` | 已解析依赖的 port |
| `podFQDNs` | 已解析依赖的 Pod FQDN 列表 |
| `username` | 已解析依赖的用户名 |
| `password` | 已解析依赖的密码 |

---

## 参考文档

- `docs/research/koda-env-realtime-classification.md`
- `docs/research/koda-port-and-headless-service-research.md`
- Koda 源码：`internal/controller/core/component/env_projection.go`
- Koda 源码：`internal/controller/core/component/service_builder.go`
- Koda 源码：`internal/controller/core/component/service_update.go`
