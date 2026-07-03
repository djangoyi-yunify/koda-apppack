## 1. 脚本框架

- [x] 1.1 创建 `scripts/init.sh`，设置 shebang 与 `set -euo pipefail`
- [x] 1.2 实现组件参数解析（`server` / `sentinel`），无效参数时退出并报错
- [x] 1.3 定义环境变量默认值与必填校验（`REDIS_CLUSTER_ID` 必填）

## 2. 公共工具函数

- [x] 2.1 实现 `derive_password(username)`：输出 `sha256hex("${REDIS_CLUSTER_ID}:<username>")`
- [x] 2.2 实现 `ensure_dir(path)`：目录不存在时创建
- [x] 2.3 实现 `ensure_acl_user(file, username, rule)`：原行替换或追加
- [x] 2.4 实现 `ensure_default_user(file)`：`default` 用户不存在时追加 `user default off`

## 3. server 组件初始化

- [x] 3.1 创建 `/data/redis` 与 `/data/logs` 目录
- [x] 3.2 生成 `/data/redis-runtime.conf`，包含 `include`、`dir`、`aclfile`、`masteruser`、`masterauth`
- [x] 3.3 初始化 `/data/users.acl`，确保 `op-replica` 与 `default off`

## 4. sentinel 组件初始化

- [x] 4.1 创建 `/data/logs` 目录，不创建 sentinel 数据目录
- [x] 4.2 生成 `/data/sentinel.conf`，包含 `port`、`aclfile`、`sentinel sentinel-user`、`sentinel sentinel-pass`
- [x] 4.3 初始化 `/data/users.acl`，确保 `op-sentinel` 与 `default off`

## 5. 幂等性验证

- [x] 5.1 验证主配置文件已存在时不会被覆盖
- [x] 5.2 验证 ACL 中运维用户已存在时会被原行替换
- [x] 5.3 验证 ACL 中 `default` 用户已存在时不会被覆盖

## 6. 本地测试

- [x] 6.1 在本地 Bash 环境运行 `init.sh server`，检查输出文件内容
- [x] 6.2 在本地 Bash 环境运行 `init.sh sentinel`，检查输出文件内容
- [x] 6.3 验证 `REDIS_CLUSTER_ID` 未设置时脚本失败
- [x] 6.4 验证相同 `REDIS_CLUSTER_ID` 产生相同密码，不同 ID 产生不同密码

## 7. 提交与收尾

- [ ] 7.1 使用 `git status` / `git diff` 检查变更范围
- [ ] 7.2 按 `agent-rules/git.md` 规范提交变更
