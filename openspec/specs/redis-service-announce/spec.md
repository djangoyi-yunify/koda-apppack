# Redis Service Announce

## Purpose

定义 Redis AppPack 中 `replica-announce-ip` 与 `replica-announce-port` 的来源、生成位置与回退策略，确保复制、Sentinel 与客户端访问使用一致的地址。

## ADDED Requirements

### Requirement: replica-announce 来源优先级

`scripts/init.sh server` SHALL 按以下优先级确定 `replica-announce-ip` 与 `replica-announce-port`：

1. HostNetwork 模式（`REDIS_HOST_NETWORK_PORT` 存在）；
2. per-pod NodePort Service（`REDIS_ADVERTISED_PORT` 存在，未来支持）；
3. per-pod LoadBalancer Service（`REDIS_LB_ADVERTISED_HOST` / `REDIS_LB_ADVERTISED_PORT` 存在，未来支持）；
4. Headless Service 回退。

#### Scenario: 无外部 Service 时回退到 Headless Service
- **WHEN** 未配置任何外部 per-pod Service 且未启用 HostNetwork
- **THEN** `replica-announce-ip` 等于当前 Pod 的 FQDN
- **AND** `replica-announce-port` 等于 Redis 容器端口

#### Scenario: HostNetwork 模式
- **WHEN** 启用 HostNetwork 且 `REDIS_HOST_NETWORK_PORT` 已设置
- **THEN** `replica-announce-ip` 等于当前 Pod 所在节点的 IP
- **AND** `replica-announce-port` 等于 `REDIS_HOST_NETWORK_PORT`

#### Scenario: per-pod NodePort Service（未来支持）
- **WHEN** per-pod NodePort Service 已配置且 `REDIS_ADVERTISED_PORT` 包含当前 Pod ordinal 对应的 `svcName:nodePort`
- **THEN** `replica-announce-ip` 等于当前 Pod 所在节点的 IP
- **AND** `replica-announce-port` 等于匹配的 `nodePort`

#### Scenario: per-pod LoadBalancer Service（未来支持）
- **WHEN** per-pod LoadBalancer Service 已配置且 `REDIS_LB_ADVERTISED_HOST` / `REDIS_LB_ADVERTISED_PORT` 包含当前 Pod ordinal 对应的条目
- **THEN** `replica-announce-ip` 等于匹配的 LB ingress host
- **AND** `replica-announce-port` 等于匹配的 LB service port

### Requirement: ClusterIP Service 不用于 replica-announce

共享的 ClusterIP Service SHALL NOT 作为 `replica-announce-ip` / `replica-announce-port` 的来源。

#### Scenario: 仅配置共享 ClusterIP Service
- **WHEN** 只声明了共享 ClusterIP Service
- **THEN** `init.sh` SHALL 忽略该 Service
- **AND** 回退到 Headless Service 推导 announce 值

### Requirement: Redis 监听端口等于容器端口

Redis 主配置文件中的监听端口 SHALL 始终等于 `ComponentDefinition` 中声明的容器端口。

#### Scenario: 默认非 TLS 模式
- **WHEN** TLS 未启用
- **THEN** `redis-runtime.conf` 包含 `port $REDIS_PORT`
- **AND** `$REDIS_PORT` 等于容器 `containerPort`

#### Scenario: TLS 模式
- **WHEN** TLS 启用
- **THEN** `redis-runtime.conf` 包含 `tls-port $REDIS_PORT` 与 `port 0`
- **AND** `$REDIS_PORT` 等于容器 `containerPort`

### Requirement: announce 配置隔离存储

`replica-announce-ip` 与 `replica-announce-port` SHALL 写入独立配置文件，并通过 `include` 被主配置文件引用。

#### Scenario: 生成 redis-announce.conf
- **WHEN** 执行 `init.sh server`
- **THEN** `/data/redis-announce.conf` 文件存在或被更新
- **AND** 文件包含 `replica-announce-ip <value>`
- **AND** 文件包含 `replica-announce-port <value>`

#### Scenario: redis-runtime.conf 引入 announce 配置
- **WHEN** `init.sh server` 生成 `redis-runtime.conf`
- **THEN** 该文件包含 `include /data/redis-announce.conf`
