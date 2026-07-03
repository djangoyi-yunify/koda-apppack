## ADDED Requirements

### Requirement: Redis `include` 隔离性
Redis 主配置文件通过 `include` 引入只读模板后，`CONFIG REWRITE` 必须只修改主配置文件，不得修改模板文件。

#### Scenario: CONFIG REWRITE 不污染模板
- **WHEN** 副本实例以自身的 `redis-runtime.conf` 为主文件启动，且该文件通过 `include` 引用同目录下的 `redis-template.conf`
- **AND** 副本实例通过 `redis-cli` 执行 `REPLICAOF` 建立主从关系
- **AND** 副本实例上执行 `CONFIG REWRITE`
- **THEN** `redis-runtime.conf` 被更新并包含 `replicaof` 与 `masterauth`
- **AND** `redis-template.conf` 的内容保持不变

### Requirement: CONFIG REWRITE 单一参数隔离性
使用与复制无关的简单参数 `maxmemory` 单独验证 `CONFIG REWRITE` 的写文件边界，确保变更只写入主配置文件，不污染只读模板。

#### Scenario: maxmemory 变更后只写入运行时文件
- **WHEN** Redis 实例以 `redis-runtime.conf` 为主文件启动
- **AND** `redis-runtime.conf` 通过 `include` 引用同目录下的 `redis-template.conf`
- **AND** `redis-template.conf` 包含 `maxmemory 256mb`
- **AND** `redis-runtime.conf` 不包含 `maxmemory`
- **AND** 执行 `CONFIG SET maxmemory 512mb`
- **AND** 执行 `CONFIG REWRITE`
- **THEN** `redis-runtime.conf` 包含 `maxmemory 512mb`
- **AND** `redis-template.conf` 中 `maxmemory` 仍为 `256mb`

### Requirement: Redis 副本配置持久化
副本实例的主配置文件必须持久保存 `replicaof` 与 `masterauth`，以便进程重启后恢复正确角色。

#### Scenario: 通过 redis-cli 建立复制关系后配置落盘
- **WHEN** 副本实例以不包含 `replicaof` 的主配置文件启动
- **AND** 使用 `redis-cli` 执行 `REPLICAOF` 指向主库
- **AND** 执行 `CONFIG REWRITE`
- **THEN** 副本主配置文件包含 `replicaof` 与 `masterauth`

#### Scenario: 副本重启后恢复角色
- **WHEN** 副本实例以已持久化的、包含 `replicaof` 和 `masterauth` 的主配置文件启动
- **AND** 主库可达
- **THEN** 副本以 `role:slave` 启动并连接主库

### Requirement: Redis 故障转移后角色持久化
故障转移导致原副本提升为主库后，其主配置文件必须被更新以反映新角色；原主库重新加入后必须被改写为副本配置。

#### Scenario: 提升后的副本保持主库角色
- **WHEN** Sentinel 触发故障转移，原副本被提升为主库
- **AND** 新主库上执行 `CONFIG REWRITE`
- **THEN** 新主库的主配置文件中不再包含指向旧主库的 `replicaof`

### Requirement: Sentinel 认证配置生效
Sentinel 必须通过 `requirepass` 保护自身管理接口，并通过 `auth-pass` 认证有密码保护的 Redis 主库。

#### Scenario: 客户端认证 Sentinel
- **WHEN** Sentinel 配置中包含 `requirepass sentinelpass`
- **THEN** 未提供密码的客户端无法执行 Sentinel 命令
- **AND** 提供正确密码的客户端可以执行 Sentinel 命令

#### Scenario: Sentinel 管理有密码的 Redis
- **WHEN** Sentinel 配置中包含 `sentinel auth-pass mymaster defaultpass`
- **AND** Redis 主库配置了 `requirepass defaultpass`
- **THEN** Sentinel 能正常监控该主库并执行故障转移

### Requirement: Sentinel 拓扑信息持久化
Sentinel 必须将发现的副本信息与配置纪元写入自身配置文件，并在重启后恢复拓扑认知。

#### Scenario: Sentinel 自动记录 known-replica
- **WHEN** Sentinel 监控一主一从拓扑
- **THEN** `sentinel.conf` 中包含 `sentinel known-replica mymaster <replica-ip> <replica-port>`

#### Scenario: Sentinel 记录 config-epoch
- **WHEN** Sentinel 完成一次故障转移
- **THEN** `sentinel.conf` 中的 `sentinel config-epoch mymaster` 值大于故障转移前的值

#### Scenario: Sentinel 重启后恢复拓扑认知
- **WHEN** Sentinel 进程被停止后重新启动，使用同一个持久化的 `sentinel.conf`
- **THEN** Sentinel 仍然识别当前主库的地址与角色
- **AND** Sentinel 不再将已下线的旧主库视为主库
