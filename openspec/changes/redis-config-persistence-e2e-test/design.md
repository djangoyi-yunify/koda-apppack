## Context

`docs/research/redis-config-persistence-analysis.md` 提出：在容器环境中，Redis 运行时会回写 `redis.conf`、Sentinel 会回写 `sentinel.conf`。为避免只读 ConfigMap 挂载导致回写失败，以及避免 `emptyDir` 等临时存储导致重启丢失状态，推荐采用“运行时配置为主文件 + `include` 静态模板”的分离方案。

本变更不实现 Koda AppPack 的生产代码，而是为上述机制编写最小化 e2e 测试，使用本地 Redis 7.2.14 二进制验证关键假设。

## Goals / Non-Goals

**Goals:**
- 使用本地 `redis-server` / `redis-cli` / `redis-sentinel` 验证 Redis 7.2.14 的 `include` + `CONFIG REWRITE` 行为。
- 验证 `replicaof` / `masterauth` 在持久化运行时配置文件中的正确回写与重启恢复。
- 验证 Sentinel 的 `requirepass`、`auth-pass`、`known-replica`、`config-epoch` 回写与重启恢复。
- 测试脚本遵循 `agent-rules/testing.md` 的粒度要求，每个任务独立可运行。

**Non-Goals:**
- 不验证 ACL 文件持久化（已在边界中排除）。
- 不验证“模板当主文件”的反面用法。
- 不使用 Docker、Pod 或 Kubernetes 运行测试。
- 不直接修改 `charts/redis-pack/`、`scripts/`、`configs/` 等生产交付物。

## Decisions

### 使用本地 redis-server 进程而非容器
- **原因**：用户明确要求不考虑 Koda，且使用开发环境提供的 `redis-server`。本地进程启动快、调试方便、无需容器运行时。
- **替代方案**：Docker Compose 更接近 K8s 卷行为，但与本边界冲突，不采用。

### 使用 Bash 编写测试脚本
- **原因**：项目 `AGENT.md` 已规定 Shell 脚本统一使用 Bash，并启用 `set -euo pipefail`。Bash 的数组、进程管理、`[[ ]]` 等特性能显著简化测试脚本。
- **替代方案**：POSIX sh 可移植性更强，但进程与 PID 管理更繁琐，与项目标准不符。

### 测试目录放在 `tests/e2e/redis-config-persistence/`
- **原因**：与现有 `tests/render-test.sh` 区分，`e2e` 子目录表明这是运行时行为测试，不是 Chart 渲染测试。

### 每个任务一个独立脚本
- **原因**：`agent-rules/testing.md` 要求“将测试拆分为独立的、可单独运行的最小任务”。每个脚本自己负责 setup / run / cleanup，失败即停止。
- **任务划分**：
  1. **CONFIG REWRITE 隔离性（单独验证）**：使用 `maxmemory` 单一参数，验证 `CONFIG SET` + `CONFIG REWRITE` 只修改运行时主文件，不污染静态模板。
  2. **Redis 副本配置持久化**：启动主从并配置密码；通过 `redis-cli` 建立复制关系，验证 `replicaof` / `masterauth` 写入运行时配置文件且模板未被修改；重启 replica 验证持久化配置生效；启动配置 `requirepass` 和 `auth-pass` 的 Sentinel 并触发 failover，验证 `replicaof` 更新。
  3. **Sentinel 持久化**：独立启动主从 + Sentinel，先执行一次 failover 建立基线，再执行第二次 failover，只验证 `sentinel.conf` 中的 `known-replica` 与 `config-epoch` 更新，以及 Sentinel 重启后拓扑恢复。
  4. **完整回归测试**：顺序调用以上任务。

### 使用临时目录模拟持久卷
- **原因**：本地进程没有 K8s PVC，使用 `mktemp -d` 创建的目录模拟持久化存储，重启进程时复用同一目录即可验证持久化。

### 所有运行时文件放在 `/tmp` 下，每个实例拥有独立的配置文件与数据目录
- **原因**：用户明确要求测试配置与临时数据均存放到 `/tmp`，且每个 Redis 运行时实例使用独立的配置文件和数据目录，避免实例间相互污染，便于清理与调试。
- **目录结构**：

  ```text
  /tmp/redis-cfg-e2e-XXXX/
  ├── master/
  │   ├── redis-template.conf      # 实例独立的只读模板
  │   ├── redis-runtime.conf       # 运行时主文件，include ./redis-template.conf
  │   └── data/                    # 独立数据目录（dir 配置指向这里）
  ├── replica/
  │   ├── redis-template.conf
  │   ├── redis-runtime.conf
  │   └── data/
  └── sentinel/
      ├── sentinel.conf
      └── data/
  ```

- **说明**：
  - 每个 Redis 实例拥有独立的 `redis-template.conf`、`redis-runtime.conf` 和 `data/` 目录，互不共享。
  - `redis-runtime.conf` 通过相对路径 `include ./redis-template.conf` 引入同目录下的模板。
  - `redis-template.conf` 是只读的，`CONFIG REWRITE` 不得修改它。
  - 每个实例的 `data/` 目录在进程重启时复用，以验证持久化；测试整体结束时由 `trap cleanup` 删除整个 `/tmp/redis-cfg-e2e-XXXX/`。
  - Sentinel 没有模板概念，只保留自身的 `sentinel.conf` 和 `data/`。

### 使用 `SENTINEL FAILOVER` 触发故障转移
- **原因**：比杀掉主库更可控、更快，且同样会触发 Sentinel 的拓扑更新与 Redis 的 `CONFIG REWRITE`。
- **替代方案**：`DEBUG SEGFAULT` 或 `SHUTDOWN NOSAVE` 更真实，但等待主观下线 + failover-timeout 时间较长，不稳定。

### 认证使用 `REDISCLI_AUTH` 环境变量
- **原因**：避免 `redis-cli -a` 在命令行泄露密码并产生 warn；`REDISCLI_AUTH` 对 Redis 和 Sentinel 均生效。

### 清理策略
- **独立运行单个任务时**：每个任务脚本负责自己的 setup 与 cleanup，运行结束后自动清理进程与临时目录，避免留下孤儿进程。
- **`run-all.sh` 执行完整流程时**：
  - 通过环境变量 `E2E_NO_CLEANUP=1` 禁用每个任务脚本的默认 cleanup。
  - 逐个执行 task-01、task-02、task-03 期间不单独清理，所有单个任务执行完毕后再统一清理一次。
  - 执行回归测试前必须再次执行清理，确保回归测试从一个干净状态开始。
  - 回归测试完毕后不自动清理，脚本提示用户检查 `/tmp/redis-cfg-e2e-XXXX/` 下的配置文件与进程状态，待用户确认后再执行最终清理。
- **原因**：
  - 所有任务均独立可运行，统一在单个任务阶段结束后清理是为了减少重复清理开销并保留现场供一次性检查。
  - 回归测试前清理可避免前序任务的状态干扰回归结果。
  - 回归测试后保留现场便于人工排查；确认后再清理可防止误删有用的调试信息。

## Risks / Trade-offs

- **风险**：本地 Redis 版本与生产版本不一致，导致行为差异。
  - **缓解**：在脚本开头检查 `redis-server --version`，要求 7.2.14，否则失败。
- **风险**：端口 6379/6380/26379 被占用导致测试失败。
  - **缓解**：脚本启动前检测端口占用；或支持通过环境变量覆盖端口。
- **风险**：Sentinel 单实例配置（quorum=1）与生产多 Sentinel 集群行为不同。
  - **缓解**：本测试仅验证配置回写与持久化机制，不验证分布式一致性；在文档中说明范围。
- **风险**：测试任务之间有依赖（例如 Sentinel 测试依赖 Redis 主从已建立）。
  - **缓解**：每个任务脚本仍独立负责启动自己需要的进程，并通过 `wait_for` 函数确保就绪；回归脚本按正确顺序调用它们。

## Migration Plan

不适用。本变更只新增测试脚本与文档，不影响现有系统运行。

## Open Questions

- 是否需要在 CI 中运行这些 e2e 测试？如果是，需要确保 CI 环境安装 Redis 7.2.14。
- 是否需要为每个任务脚本提供 `TEST_REDIS_PORT` / `TEST_REPLICA_PORT` / `TEST_SENTINEL_PORT` 环境变量覆盖能力？
