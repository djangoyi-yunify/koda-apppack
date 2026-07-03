## Context

当前 `scripts/lifecycle.sh` 把统一入口、公共 helper（JSON 输出、密码推导、redis-cli 封装）和 `postProvision` 业务逻辑全部放在一个文件中。`postProvision` 分支已经包含 redis-server 和 redis-sentinel 两条路径，文件接近 200 行。未来还要加入 `roleProbe`、`availableProbe`、`switchover`、`memberJoin`、`memberLeave`、`reconfigure` 等动作，单文件会快速膨胀到难以维护。

本次重构在保持对外调用契约不变的前提下，把实现拆成三个层次：入口分发器、公共 helper、按动作划分的函数库。

## Goals / Non-Goals

**Goals：**

- 保持外部调用接口不变：`/scripts/lifecycle.sh <action> <json-params>`；
- 把 `lifecycle.sh` 改造为薄分发器，只负责 source helper、source action 函数库、按 `$1` 调用函数；
- 提取公共 helper 到 `scripts/helper.sh`；
- 把 `postProvision` 实现移到 `scripts/actions/post-provision.sh`，以函数形式定义；
- 预留其他 action 脚本文件，保持项目结构对未来扩展友好。

**Non-Goals：**

- 不修改 `postProvision` 的业务行为；
- 不修改 `scripts/init.sh`；
- 不实现其他生命周期动作（只预留文件/空函数）。

## Decisions

### 1. 用 `source` 加载 action 函数库，而不是 `exec`

**决策**：`lifecycle.sh` 在启动时 `source` 所有 action 脚本，把函数注册到当前 shell，然后根据 `$1` 调用对应函数。

**理由**：
- action 脚本可以访问 `lifecycle.sh` 已经 source 的 `helper.sh`，避免重复 source 和函数导出；
- 环境变量默认值/推导由 `lifecycle.sh` 统一准备，action 函数直接使用；
- action 脚本无法被外部直接执行，确保入口唯一。

**替代方案**：`exec` 调用独立 action 脚本。放弃原因：每个 action 脚本都要自己 source `helper.sh`，且无法阻止外部直接调用。

### 2. 公共 helper 放在 `scripts/helper.sh`，不用 `lib/` 目录

**决策**：公共 helper 文件直接放在 `scripts/helper.sh`。

**理由**：
- helper 不复杂，单层目录更直接；
- 与 `scripts/init.sh`、`scripts/lifecycle.sh` 平级，符合现有项目结构。

### 3. 静态列表 source action 脚本

**决策**：`lifecycle.sh` 显式列出要 source 的 action 脚本，不用 `actions/*.sh` 动态扫描。

**理由**：
- 加载顺序和依赖关系显式可控；
- 新增 action 时修改一行即可，出错时定位更快。

### 4. 函数名与 action 名保持一致

**决策**：`postProvision` action 对应 `postProvision()` 函数，`roleProbe` 对应 `roleProbe()`，以此类推。

**理由**：
- dispatch 逻辑直观：`postProvision) postProvision ;;`；
- 减少命名转换带来的认知负担。

### 5. 未实现动作在 `lifecycle.sh` 直接返回失败

**决策**：对于尚未实现的 action，`lifecycle.sh` 的 case 分支直接调用 `fail_json` 返回"not implemented"。

**理由**：
- 不引入半实现的空函数；
- 失败原因集中、明确。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| action 脚本误写顶层执行代码，导致 source 时意外执行 | 约定：action 脚本只定义函数，不执行顶层代码；代码审查时重点检查。 |
| 函数名冲突 | 函数名与 action 名一致，具有唯一性；新增 action 时检查命名。 |
| `source` 顺序导致依赖问题 | 静态列表，`helper.sh` 最先 source，action 脚本之间无依赖。 |
| 重构后行为 regression | 保持业务逻辑不变，仅移动代码位置；重构后运行与之前相同的测试用例。 |
