## Context

Redis AppPack 当前已实现 `postProvision` 与 `accountProvision`，`scripts/actions/reconfigure.sh` 仍是占位实现，直接返回 `not implemented`。Koda 通过 `lifecycle.actions.reconfigure`（实际调用为 `configReconfigure:<config-name>`）在组件运行后执行配置热加载；没有该动作，声明的可热加载参数无法在不重启 Pod 的情况下生效。

本次设计基于 koda-agent 的调用契约：exec action 的参数以环境变量形式注入，并覆盖目标容器中同名变量。`reconfigure` 的核心输入 `KODA_CONFIG_CHANGED_PARAMETERS` 正是由 koda-agent 注入的 JSON 数组。

## Goals / Non-Goals

**Goals：**
- 实现 `reconfigure` 动作，支持 `redis-server` 与 `redis-sentinel` 组件。
- 通过 `CONFIG SET` 应用新增/更新参数，通过默认值表恢复 removed 参数。
- 成功应用后调用 `CONFIG REWRITE`，确保运行中配置与持久化配置一致。
- 保持现有 `include` 配置模型不变，不修改 `scripts/init.sh`。
- 更新 `docs/design/redis-lifecycle-design.md`，补充 `reconfigure` 设计与 koda-agent 调用契约。

**Non-Goals：**
- 不实现 Sentinel master 专属参数（如 `sentinel.down-after-milliseconds`）的热加载。
- 不处理需要重启才能生效的 `immutable` / `restartOnly` 参数（Koda policy 不会把它们送到 reconfigure）。
- 不修改 `accountProvision` 的参数读取方式（该修复属于独立 change）。
- 不引入 `jq` 以外的 JSON 解析依赖。

## Decisions

### 1. 输入源：`KODA_CONFIG_CHANGED_PARAMETERS`

**选择：** 以 koda-agent 注入的 `KODA_CONFIG_CHANGED_PARAMETERS` JSON 数组为唯一输入源。

**理由：**
- Koda #229 明确将其作为 canonical payload。
- 保留参数原始 key 名，避免 `KODA_CONFIG_PARAM_*` alias 反向映射的歧义。
- 能完整表达 added/updated/removed 参数及 `class` 元数据。

**替代方案：** 使用 `KODA_CONFIG_PARAM_*` 环境变量别名。 rejected，因为 alias 是 lossy 的（如 `maxmemory-policy` 与 `maxmemory_policy` 无法区分），且无法表示 removed 参数。

### 2. JSON 解析：`jq`

**选择：** 使用 `jq` 解析 `KODA_CONFIG_CHANGED_PARAMETERS`。

**理由：**
- 解析 JSON 数组比纯 bash regex 更可靠、可维护。
- 与项目后续将所有 JSON 解析迁移到 `jq` 的方向一致。
- `jq` 缺失时直接 `fail_json`，行为明确。

**替代方案：** 纯 bash regex。rejected，因为数组 + null 值解析过于脆弱，且与项目演进方向不符。

### 3. 配置模型：保留 `include`

**选择：** 保持 `init.sh` 现有 `include /etc/redis/redis-template.conf` 模型；`reconfigure` 每次成功后调用 `CONFIG REWRITE`。

**理由：**
- 只要 reconfigure 成功调用 `CONFIG REWRITE`，主配置中的显式项与模板中的值保持一致，重启不会产生覆盖冲突。
- 避免了配置项级合并或整文件拷贝的复杂逻辑。
- 现有 e2e 测试 task-01 已验证该行为。

**替代方案：** init.sh 拷贝模板内容到主配置。rejected，因为需要复杂的合并逻辑来保留运行时生成项（如 `replicaof`），且收益有限。

### 4. removed 参数：默认值表

**选择：** removed 参数通过 `CONFIG SET key <defaultValue>` 恢复默认值；默认值表放在 `scripts/actions/reconfigure.sh` 中，可扩展。

**理由：**
- 实现真正的热卸载，内存立即回到默认行为。
- 随后 `CONFIG REWRITE` 写入主配置，重启后仍一致。
- 表结构简单，新增参数只需追加一行。

**替代方案：** 直接从主配置删除该行。rejected，因为 Redis 没有通用 reset 命令，且删除操作在 `CONFIG REWRITE` 后 fragile。

### 5. 组件分支：按 `KODA_COMPONENT_TYPE`

**选择：** 根据 `KODA_COMPONENT_TYPE` 选择端口与 operator 用户；`redis-sentinel` 也视为通用 Redis 进程处理，拒绝 `sentinel.*` 参数。

**理由：**
- 与 `postProvision`、`accountProvision` 保持一致。
- Sentinel 作为 Redis 进程支持通用 `CONFIG SET`，但 master 专属参数不在本次范围。

### 6. 错误策略：严格失败

**选择：** 遇到以下情况立即 `fail_json`：
- Redis 返回 `ERR`（不支持动态加载的参数）
- `sentinel.*` 类参数
- removed 参数不在默认值表
- `jq` 缺失或 JSON 解析失败

**理由：** reconfigure 只应收到 `reloadOnly` / `reloadThenRestart` 参数，失败能快速暴露 Koda 分类或输入错误。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| `jq` 未安装在目标镜像中 | `fail_json` 明确报错；镜像构建时确保 `jq` 存在 |
| reconfigure 在 `CONFIG SET` 后、`CONFIG REWRITE` 前失败 | Koda 会重试；重试成功前存在短暂不一致窗口 |
| removed 参数默认值表不完整 | 不在表中的参数 `fail_json`，避免不可预期行为 |
| 用户模板中误写运行时关键参数（`dir`、`aclfile` 等） | 信任模板层不会触碰；如触碰，Redis 会报错或 init.sh 负责保证 |
| `CONFIG REWRITE` 把配置追加到主配置导致文件膨胀 | 配置项正确性优先；文件冗余不影响语义 |

## Open Questions

- 无。
