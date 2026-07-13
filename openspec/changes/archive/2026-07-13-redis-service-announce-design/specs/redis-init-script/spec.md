# Redis Init Script

## Purpose

本能力定义 `scripts/init.sh` 的行为变更：新增服务宣告配置生成，并在 Pod 重建时通过 Sentinel 修正 `replicaof`。

## ADDED Requirements

### Requirement: server 组件生成 redis-announce.conf

`scripts/init.sh server` SHALL 生成或更新 `/data/redis-announce.conf`，写入当前 Pod 的 `replica-announce-ip` 与 `replica-announce-port`。

#### Scenario: 首次创建时生成 announce 配置
- **WHEN** 执行 `init.sh server` 且 `/data/redis-announce.conf` 不存在
- **THEN** 该文件被创建
- **AND** 文件包含 `replica-announce-ip` 与 `replica-announce-port`

#### Scenario: Pod 重建时更新 announce 配置
- **GIVEN** `/data/redis-announce.conf` 已存在
- **WHEN** 执行 `init.sh server`
- **THEN** 该文件被覆盖为当前 Pod 最新的 announce 值

#### Scenario: Headless 回退时 announce 值
- **WHEN** 未配置外部 Service 且未启用 HostNetwork
- **THEN** `replica-announce-ip` 等于当前 Pod FQDN
- **AND** `replica-announce-port` 等于 Redis 容器端口

#### Scenario: HostNetwork 模式 announce 值
- **WHEN** 启用 HostNetwork 且 `REDIS_HOST_NETWORK_PORT=30001`
- **THEN** `replica-announce-ip` 等于当前 Pod 所在节点 IP
- **AND** `replica-announce-port` 等于 `30001`

### Requirement: server 组件在 Pod 重建时通过 Sentinel 更新 replicaof

当 `redis-runtime.conf` 已存在且 Sentinel 启用时，`scripts/init.sh server` SHALL 查询 Sentinel 获取当前 master，并更新 `redis-runtime.conf` 中的 `replicaof` 行；若当前 Pod 自身即为 master，则移除 `replicaof`。

#### Scenario: 故障转移后旧 master 重建
- **GIVEN** `redis-runtime.conf` 已存在
- **AND** Sentinel 已启用
- **AND** Sentinel 返回的当前 master 是 `redis-server-1.demo-redis-headless`
- **WHEN** 在 `redis-server-0` 上执行 `init.sh server`
- **THEN** `redis-runtime.conf` 中的 `replicaof` 被更新为指向 `redis-server-1.demo-redis-headless`

#### Scenario: 当前 Pod 是当前 master
- **GIVEN** `redis-runtime.conf` 已存在
- **AND** Sentinel 已启用
- **AND** Sentinel 返回的当前 master 与当前 Pod FQDN 一致
- **WHEN** 执行 `init.sh server`
- **THEN** `redis-runtime.conf` 中不包含指向其他节点的 `replicaof`

#### Scenario: 首次创建时跳过 Sentinel 查询
- **GIVEN** `redis-runtime.conf` 不存在
- **WHEN** 执行 `init.sh server`
- **THEN** 不查询 Sentinel
- **AND** `redis-runtime.conf` 不包含 `replicaof`

## MODIFIED Requirements

### Requirement: server 组件生成 Redis 主配置文件

`scripts/init.sh server` SHALL 在 `REDIS_RUNTIME_CONFIG` 路径生成 Redis 主配置文件。

#### Scenario: 生成 redis-runtime.conf
- **WHEN** 执行 `init.sh server`
- **THEN** `REDIS_RUNTIME_CONFIG` 文件存在
- **AND** 文件包含 `include` 只读模板
- **AND** 文件包含 `include /data/redis-announce.conf`
- **AND** 文件包含 `dir` 指向 Redis 数据目录
- **AND** 文件包含 `aclfile` 指向 ACL 文件
- **AND** 文件包含 `masteruser op-replica`
- **AND** 文件包含 `masterauth` 派生明文密码（`derive_password_plaintext` 输出）
- **AND** 文件不包含 `replicaof`

### Requirement: 主配置文件幂等

脚本 SHALL 不覆盖已存在的主配置文件中的运行时状态；但在启用 Sentinel 的 Pod 重建场景下，允许更新 `replicaof` 行。

#### Scenario: redis-runtime.conf 已存在
- **GIVEN** `REDIS_RUNTIME_CONFIG` 文件已存在
- **WHEN** 执行 `init.sh server`
- **THEN** 除 `replicaof` 行外，原文件内容保持不变

#### Scenario: sentinel.conf 已存在
- **GIVEN** `SENTINEL_CONFIG` 文件已存在
- **WHEN** 执行 `init.sh sentinel`
- **THEN** 原文件内容保持不变
