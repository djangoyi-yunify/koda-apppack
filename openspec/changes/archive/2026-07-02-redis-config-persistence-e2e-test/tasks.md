## 1. 测试基础设施

- [x] 1.1 创建 `tests/e2e/redis-config-persistence/` 目录结构
- [x] 1.2 编写 `lib/common.sh`：Redis 版本检查、端口检测、在 `/tmp` 下创建隔离的实例目录（每个实例独立的配置文件和数据目录）、进程启动/停止/清理、`wait_for` 辅助函数
- [x] 1.3 编写 `lib/assert.sh`：断言函数（`assert_file_contains`、`assert_role`、`assert_config_epoch` 等）
- [x] 1.4 验证本地 Redis 版本为 7.2.14，否则测试失败并给出明确提示

## 2. CONFIG REWRITE 隔离性（单独验证）

- [x] 2.1 编写 `task-01-maxmemory-config-rewrite.sh`，只验证 `maxmemory` 一个参数：
  - 步骤 1：在 `redis-template.conf` 中设置 `maxmemory 256mb`，`redis-runtime.conf` 仅包含 `include ./redis-template.conf`，启动 Redis 实例
  - 步骤 2：使用 `redis-cli` 执行 `CONFIG SET maxmemory 512mb`，再执行 `CONFIG REWRITE`
  - 步骤 3：观察 `maxmemory` 在配置文件中的变化：`redis-runtime.conf` 应新增 `maxmemory 512mb`，`redis-template.conf` 保持 `maxmemory 256mb` 不变

## 3. Redis 副本配置持久化

- [x] 3.1 编写 `task-02-redis-replica-config-persistence.sh`，包含以下步骤：
  - 步骤 1：启动 master 和 replica 实例，配置 `requirepass`
  - 步骤 2：使用 `redis-cli` 在 replica 上执行 `REPLICAOF` 建立主从关系，触发 `CONFIG REWRITE`，验证 `replicaof` / `masterauth` 写入 replica 的主配置文件，且同目录下的 `redis-template.conf` 未被修改
  - 步骤 3：停止并重新启动 replica 实例，使用同一个持久化的主配置文件，验证 replica 以 `role:slave` 启动并重新连接 master
  - 步骤 4：启动配置有 `requirepass` 和 `auth-pass` 的 Sentinel 实例，触发 `SENTINEL FAILOVER`，验证原 replica 提升为主库后其主配置文件中的 `replicaof` 被移除或更新

## 4. Sentinel 持久化

- [x] 4.1 编写 `task-03-sentinel-persistence.sh`，独立启动主从 + Sentinel 实例：
  - 步骤 1：启动 master、replica 和配置有 `requirepass` / `auth-pass` 的 Sentinel 实例
  - 步骤 2：执行第一次 `SENTINEL FAILOVER`，建立 `sentinel.conf` 基线（记录 `known-replica` 与 `config-epoch`）
  - 步骤 3：再次触发 `SENTINEL FAILOVER`，观察 `sentinel.conf` 的变化：验证 `known-replica` 更新为新的副本地址，且 `config-epoch` 递增
  - 步骤 4：重启 Sentinel 实例，验证其从持久化的 `sentinel.conf` 恢复拓扑认知

## 5. 回归与入口

- [x] 5.1 编写 `run-all.sh`，支持以下执行模式：
  - 单个任务模式：默认每个 task 脚本运行结束后自行清理
  - 完整流程模式：
    - 设置 `E2E_NO_CLEANUP=1`，顺序调用 task-01、task-02、task-03，期间不清理
    - 所有单个任务通过后，执行一次统一清理
    - 回归测试开始前，再次执行清理以确保干净状态
    - 回归测试结束后，不自动清理，提示用户检查 `/tmp/redis-cfg-e2e-XXXX/` 和进程状态，待用户确认后再清理
- [x] 5.2 在 `tests/e2e/redis-config-persistence/README.md` 中说明测试范围、环境要求、运行方式、任务划分和清理策略
- [x] 5.3 逐个运行单个任务脚本，发现并修复问题
- [x] 5.4 所有单个任务通过后，运行完整 `run-all.sh` 回归测试

## 6. 变更收尾

- [x] 6.1 使用 `git status` / `git diff` 检查变更范围，确保未引入无关文件
- [x] 6.2 按 `agent-rules/git.md` 规范提交变更
