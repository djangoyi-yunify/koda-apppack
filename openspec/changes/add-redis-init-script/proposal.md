## Why

Redis AppPack 需要在 Pod 启动前完成主配置文件、ACL 文件及必要目录的初始化。这些工作放在初始化容器中执行，可以确保 Redis/Sentinel 进程启动时拥有正确且可持久化的运行环境，同时与 Koda 控制面的后续 provision 动作解耦。

## What Changes

- 新增 `scripts/init.sh`，作为 redis-server 与 redis-sentinel 的通用初始化脚本。
- 脚本以 Kubernetes 通用语义运行，不依赖 Koda API 或特定资源结构。
- 生成 Redis 主配置文件（`redis-runtime.conf`）和 Sentinel 主配置文件（`sentinel.conf`）。
- 生成 ACL 文件（`users.acl`），按组件分别初始化 `op-replica` 或 `op-sentinel` 用户。
- 创建必要的数据目录与日志目录。

## Capabilities

### New Capabilities

- `redis-init-script`：定义 Redis 初始化容器脚本的行为、环境变量契约、文件输出及幂等性要求。

### Modified Capabilities

- 无

## Impact

- 新增 `scripts/init.sh`。
- 不影响现有 `charts/redis-pack/`、`tests/`、`configs/` 等交付物。
- 为后续 Chart 模板中 initContainers 的调用提供脚本入口。
