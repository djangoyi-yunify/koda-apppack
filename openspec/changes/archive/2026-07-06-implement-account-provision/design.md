## Context

Redis AppPack 当前已实现 `postProvision` 生命周期动作，用于组件启动后的拓扑初始化（replica 指向 primary、sentinel monitor 配置）。`scripts/lifecycle.sh` 作为统一入口，按 `$1` 分派到 `scripts/actions/*.sh` 中对应的函数；`scripts/helper.sh` 提供 JSON 输出、密码推导、redis-cli 执行等公共能力。

Koda 的 `lifecycle.actions.accountProvision` 是组件生命周期中负责账号创建、更新、删除的标准动作。当前仓库缺少该动作实现，导致声明的业务系统账号无法通过 Koda 自动落到 Redis 实例中。

## Goals / Non-Goals

**Goals:**

- 在 `scripts/lifecycle.sh` 中增加 `accountProvision` 分发分支。
- 新增 `scripts/actions/account-provision.sh`，实现 `accountProvision` 函数。
- `accountProvision` 接收 JSON 输入 `{name, password, statement}`，并输出 `{status, message, error}` JSON。
- 根据 `statement` 值区分创建/更新（ACL 规则段）与删除（`"delete"`）。
- `statement` 为空时提供默认 ACL 规则。
- 命令执行后调用 `ACL SAVE`，把 ACL 持久化到 `/data/users.acl`。
- 同时支持 `redis-server` 和 `redis-sentinel` 组件，根据 `KODA_COMPONENT_TYPE` 选择端口和 operator 用户。
- 定义 `openspec/specs/redis-account-provision/spec.md` 规范。
- 更新 `docs/design/redis-lifecycle-design.md`。

**Non-Goals:**

- 支持外部密码哈希（`#<sha256>`）传入。
- 支持复杂的 key/channel 级权限模板。
- 在实例间自动同步 ACL（依赖 `targetPodSelector: All` 让每个实例独立执行）。
- 修改 `scripts/init.sh` 的职责边界。

## Decisions

### 1. JSON 输入而非环境变量注入

`scripts/lifecycle.sh` 的入口契约是 `./lifecycle.sh <action-name> <json-params>`。`accountProvision` 与 `postProvision` 保持一致，通过 `$2` 接收 JSON。Koda 注入的环境变量（`KODA_ACCOUNT_NAME`、`KODA_ACCOUNT_PASSWORD`、`KODA_ACCOUNT_STATEMENT`）由 ComponentDefinition 的 `exec.command` 桥接层在调用前拼成 JSON；脚本层只解析 JSON，降低对 Koda 参数注入方式的依赖。

### 2. `statement` 字段的语义

Koda 的 `statements.create/update/delete` 三个字段互斥传入，只有一个字段会作为 `KODA_ACCOUNT_STATEMENT` 注入。为与 Koda 字段名对齐，JSON 第三字段使用 `statement`：

- 当 `statement == "delete"` 时，执行 `ACL DELUSER ${name}`。
- 当 `statement` 为其他非空字符串时，将其作为 ACL 规则段，执行 `ACL SETUSER ${name} on >${password} ${statement}`。
- 当 `statement` 为空字符串时，使用默认 ACL 规则（见决策 3）。
- `statement` 缺失时返回失败（脚本做防御性校验）。

这种设计让 create/update 保持为纯 ACL 规则段，delete 用特殊标记表达，空 statement 提供安全默认值，避免引入完整命令模板。

### 3. 默认 ACL 规则

参考 Redis 官方 ACL 文档：

- `default` 用户默认规则：`~* &* +@all`（对应 Redis 原生默认用户的最高权限）。
- 其他用户默认规则：`~* +@read +@write +@connection`（读写数据 + 必要的连接命令）。

默认规则在 `statement` 为空字符串时生效，也作为防御性 fallback。

### 4. `targetPodSelector: All`

Redis 的 ACL 不会通过 `REPLICAOF` 自动同步到 replica，也不会在 sentinel 之间自动同步。因此必须在每个 `redis-server` 实例和每个 `redis-sentinel` 实例上独立执行 `ACL SETUSER`/`ACL DELUSER` 和 `ACL SAVE`，所以选择 `All`。

### 5. 执行用户和端口

脚本根据 `KODA_COMPONENT_TYPE` 选择连接目标：

- `redis-server`：使用 `op-replica` 用户，连接 `REDIS_PORT`（默认 6379）。
- `redis-sentinel`：使用 `op-sentinel` 用户，连接 `SENTINEL_PORT`（默认 26379）。

两个 operator 用户均由 `init.sh` 创建并授予 `+@all`，具备执行 ACL 命令的权限。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| `statement` 误填为完整命令导致 Redis 语法错误 | 脚本校验 `statement` 不得以 `ACL ` 开头，且不得包含 `;` 或换行。 |
| `statement` 为空导致创建无权限用户 | 脚本要求 `statement` 非空，否则返回失败。 |
| 默认权限过宽或过窄 | `default` 用户给最高权限；其他用户给 `+@read +@write +@connection`，是业务可用性与安全性的折中。 |
| `ACL SAVE` 失败导致配置未持久化 | 将 `ACL SAVE` 失败视为整个动作失败。 |
| `targetPodSelector: All` 放大动作调用次数 | 每个实例只执行一次幂等操作，可接受。 |
