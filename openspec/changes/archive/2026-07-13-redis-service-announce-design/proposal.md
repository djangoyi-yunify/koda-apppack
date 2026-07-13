## Why

Redis AppPack 当前缺少对 `replica-announce-ip` / `replica-announce-port` 来源的统一约定，导致内部复制、Sentinel 故障转移与外部客户端访问的地址可能不一致。借鉴 kubeblocks-addons Redis 的调研结论，需要把服务宣告收敛到一条清晰主线：始终基于外部可访问 Service 推导，无外部 Service 时回退到 Headless Service；同时把 Redis 监听端口固定为容器端口，避免配置、Service 端口与容器端口三者错位。

## What Changes

- 重新定义 Redis 服务宣告策略：
  - `replica-announce-ip` / `replica-announce-port` 的来源仅有两类：
    - 外部 per-pod Service（NodePort / LoadBalancer / HostNetwork）；
    - 无外部 Service 时，回退为 Headless Service 给出的 Pod FQDN + 容器端口。
  - 默认 ClusterIP Service 仅用于集群内客户端访问，不作为 replica-announce 源。
- 将 Redis 配置中的 `port` / `tls-port` 固定为容器 `containerPort`，Service 端口通过 `targetPort` 映射回容器端口，外部访问端口通过 `replica-announce-port` 宣告。
- 扩展 `scripts/init.sh` 职责：
  - 首次创建时生成 `redis-announce.conf` 并被 `redis-runtime.conf` include；
  - Pod 重建时覆盖 `redis-announce.conf`，保持主配置文件中的运行时状态（`replicaof`、`masterauth` 等）不变。
  - 启用 Sentinel 时，Pod 重建阶段查询 Sentinel 获取当前 master，并原地更新 `redis-runtime.conf` 中的 `replicaof`。
- 当前阶段仅实现 Headless 回退与 HostNetwork 分支；NodePort / LoadBalancer per-pod Service 作为未来扩展点，脚本结构预留对应解析逻辑。
- 同步更新 `redis-init-script` 规格及配套测试说明。

## Capabilities

### New Capabilities

- `redis-service-announce`: Redis 服务宣告机制设计，包括外部 Service 与 Headless Service 的选择策略、announce 配置生成位置、Pod 重建更新策略。

### Modified Capabilities

- `redis-init-script`: 增加 `redis-announce.conf` 生成与更新要求；增加 Pod 重建时通过 Sentinel 修正 `replicaof` 的要求。

## Impact

- `docs/design/redis-init-script-design.md`
- `openspec/specs/redis-init-script/spec.md`
- `scripts/init.sh`（后续实现阶段）
- Redis `ComponentDefinition` 的服务契约与环境变量设计（`REDIS_PORT`、`REDIS_HOST_NETWORK_PORT`、Sentinel headless service 等）
- Redis E2E 测试用例需覆盖 announce 配置持久化与 Sentinel 故障转移后重启恢复
