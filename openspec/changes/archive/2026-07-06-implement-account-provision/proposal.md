## Why

Redis AppPack 已具备 `postProvision` 生命周期动作来完成 replication + Sentinel 拓扑初始化，但缺少 `accountProvision` 动作。Koda 通过 `lifecycle.actions.accountProvision` 在组件运行后创建、更新和删除业务账号；没有该动作，声明的系统账号无法真正落到 Redis 实例中，组件生命周期不完整。

## What Changes

- 新增 `scripts/actions/account-provision.sh`，实现 `accountProvision` 函数：
  - 接收 JSON 参数 `{name, password, statement}`；
  - `statement` 为 `"delete"` 时执行 `ACL DELUSER`；
  - 其他情况下将 `statement` 作为 ACL 规则段执行 `ACL SETUSER`；
  - `statement` 为空时提供默认 ACL 规则；
  - 命令执行成功后调用 `ACL SAVE` 持久化 ACL 文件；
  - 同时支持 `redis-server` 和 `redis-sentinel` 组件，根据 `KODA_COMPONENT_TYPE` 自动选择端口和 operator 用户。
- 在 `scripts/lifecycle.sh` 中增加 `accountProvision` 分发分支，并 source 新的 action 函数库。
- 新增 `openspec/specs/redis-account-provision/spec.md`，定义输入输出契约、幂等性、错误处理和默认权限规则。
- 更新 `docs/design/redis-lifecycle-design.md`，补充 `accountProvision` 的设计说明。

## Capabilities

### New Capabilities

- `redis-account-provision`: 定义 Redis AppPack 中 `accountProvision` 生命周期动作的 JSON 输入契约、ACL 规则处理、默认权限、目标组件和输出格式。

### Modified Capabilities

- 无。

## Impact

- `scripts/lifecycle.sh`：增加 `accountProvision` 分支。
- `scripts/actions/account-provision.sh`：新增文件。
- `openspec/specs/redis-account-provision/spec.md`：新增规范。
- `docs/design/redis-lifecycle-design.md`：补充设计文档。
