## Why

当前 `scripts/lifecycle.sh` 把生命周期动作入口、公共 helper 和 `postProvision` 实现全部耦合在一个文件中。随着未来 `roleProbe`、`availableProbe`、`switchover` 等动作加入，单文件会快速膨胀，影响可读性和维护性。本次重构在保持统一入口契约的前提下，把实现拆分为分发器、公共 helper 和按动作划分的函数库。

## What Changes

- 重构 `scripts/lifecycle.sh` 为薄分发器：source 公共 helper 和所有 action 函数库，按 `$1` 调用对应函数；
- 新增 `scripts/helper.sh`：提取 JSON 输出、密码推导、redis-cli 封装等公共 helper；
- 新增 `scripts/actions/post-provision.sh`：只定义 `postProvision` 函数，包含现有 server/sentinel 逻辑；
- 预留其他 action 脚本文件（`role-probe.sh`、`available-probe.sh`、`switchover.sh`、`member-join.sh`、`member-leave.sh`、`reconfigure.sh`），当前只定义空函数或返回未实现；
- 更新 `docs/design/redis-lifecycle-design.md`，明确"统一入口 ≠ 单文件"；
- 不修改 `scripts/init.sh` 和已实现的业务逻辑。

## Capabilities

### New Capabilities

- 无。

### Modified Capabilities

- `redis-post-provision`：需求行为不变，但实现结构从"单一 `scripts/lifecycle.sh` 脚本"改为"`lifecycle.sh` 分发器 + `helper.sh` 公共库 + `actions/post-provision.sh` 函数库"。

## Impact

- 修改 `scripts/lifecycle.sh`；
- 新增 `scripts/helper.sh`；
- 新增 `scripts/actions/` 目录及 `post-provision.sh` 等文件；
- 外部调用方式不变（仍通过 `/scripts/lifecycle.sh <action> <json-params>`）。
