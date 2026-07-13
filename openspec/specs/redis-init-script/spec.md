# Redis Init Script

## Purpose

定义 Redis AppPack 初始化容器脚本 `scripts/init.sh` 的行为、环境变量契约、文件输出及幂等性要求。该脚本在 Pod 启动前准备 Redis/Sentinel 主配置文件、ACL 文件及必要目录，与 Koda 控制面的后续 provision 动作解耦。

## ADDED Requirements

### Requirement: 脚本通过参数区分组件

`scripts/init.sh` SHALL 接受第一个参数作为组件类型，仅支持 `server` 或 `sentinel`。

#### Scenario: 使用 server 参数执行
- **WHEN** 执行 `init.sh server`
- **THEN** 脚本初始化 redis-server 相关文件与目录

#### Scenario: 使用 sentinel 参数执行
- **WHEN** 执行 `init.sh sentinel`
- **THEN** 脚本初始化 redis-sentinel 相关文件与目录

#### Scenario: 使用无效参数执行
- **WHEN** 执行 `init.sh unknown`
- **THEN** 脚本以非零状态码退出并打印错误信息

### Requirement: 缺少 REDIS_CLUSTER_ID 时失败

`scripts/init.sh` SHALL 在 `REDIS_CLUSTER_ID` 未设置时立即失败。

#### Scenario: REDIS_CLUSTER_ID 未设置
- **WHEN** `REDIS_CLUSTER_ID` 环境变量为空
- **AND** 执行 `init.sh server`
- **THEN** 脚本以非零状态码退出

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
- **AND** 文件包含 `masterauth` 派生明文密码
- **AND** 文件不包含 `replicaof`

### Requirement: server 组件初始化 ACL 文件

`scripts/init.sh server` SHALL 在 `REDIS_ACL_FILE` 路径生成或更新 ACL 文件，包含 `op-replica` 用户。

#### Scenario: 生成 users.acl
- **WHEN** 执行 `init.sh server`
- **THEN** `REDIS_ACL_FILE` 文件存在
- **AND** 文件包含 `user op-replica on #<hash> ~* &* +@all`
- **AND** 文件包含 `user default off`
- **AND** 文件不包含 `op-sentinel`

#### Scenario: op-replica 用户已存在时原行替换
- **GIVEN** ACL 文件已存在 `user op-replica on #oldhash ~* &* +@all`
- **WHEN** 执行 `init.sh server`
- **THEN** 原 `op-replica` 行被替换为新的派生密码哈希
- **AND** 文件中 `op-replica` 行数量为一

#### Scenario: default 用户已存在时保留
- **GIVEN** ACL 文件已存在自定义 `user default ...` 行
- **WHEN** 执行 `init.sh server`
- **THEN** 原 `default` 行内容保持不变

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

### Requirement: sentinel 组件生成 Sentinel 主配置文件

`scripts/init.sh sentinel` SHALL 在 `SENTINEL_CONFIG` 路径生成 Sentinel 主配置文件。

#### Scenario: 生成 sentinel.conf
- **WHEN** 执行 `init.sh sentinel`
- **THEN** `SENTINEL_CONFIG` 文件存在
- **AND** 文件包含 `port` 配置
- **AND** 文件包含 `aclfile` 指向 ACL 文件
- **AND** 文件包含 `sentinel sentinel-user op-sentinel`
- **AND** 文件包含 `sentinel sentinel-pass` 派生密码
- **AND** 文件不包含 `sentinel monitor`
- **AND** 文件不包含 `dir`

### Requirement: sentinel 组件初始化 ACL 文件

`scripts/init.sh sentinel` SHALL 在 `REDIS_ACL_FILE` 路径生成或更新 ACL 文件，包含 `op-sentinel` 用户。

#### Scenario: 生成 users.acl
- **WHEN** 执行 `init.sh sentinel`
- **THEN** `REDIS_ACL_FILE` 文件存在
- **AND** 文件包含 `user op-sentinel on #<hash> ~* &* +@all`
- **AND** 文件包含 `user default off`
- **AND** 文件不包含 `op-replica`

#### Scenario: op-sentinel 用户已存在时原行替换
- **GIVEN** ACL 文件已存在 `user op-sentinel on #oldhash ~* &* +@all`
- **WHEN** 执行 `init.sh sentinel`
- **THEN** 原 `op-sentinel` 行被替换为新的派生密码哈希
- **AND** 文件中 `op-sentinel` 行数量为一

### Requirement: 密码从 REDIS_CLUSTER_ID 派生

脚本 SHALL 使用 `sha256hex("${REDIS_CLUSTER_ID}:<username>")` 派生 `op-replica` 与 `op-sentinel` 的密码。

#### Scenario: 相同 REDIS_CLUSTER_ID 产生相同密码
- **WHEN** 使用相同 `REDIS_CLUSTER_ID` 两次执行 init
- **THEN** 两次生成的运维用户密码哈希相同

#### Scenario: 不同 REDIS_CLUSTER_ID 产生不同密码
- **WHEN** 使用不同 `REDIS_CLUSTER_ID` 执行 init
- **THEN** 生成的运维用户密码哈希不同

### Requirement: 创建必要目录

脚本 SHALL 创建组件所需的目录。

#### Scenario: server 组件创建目录
- **WHEN** 执行 `init.sh server`
- **THEN** `REDIS_DATA_DIR` 目录存在
- **AND** `LOG_DIR` 目录存在

#### Scenario: sentinel 组件创建目录
- **WHEN** 执行 `init.sh sentinel`
- **THEN** `LOG_DIR` 目录存在
- **AND** 不创建 Sentinel 数据目录

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
