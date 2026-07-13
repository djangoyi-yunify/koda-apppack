## 1. 文档与设计

- [x] 1.1 更新 `docs/design/redis-init-script-design.md`，加入 `redis-announce.conf` 生成与 Sentinel 重启恢复逻辑
- [x] 1.2 在 `docs/design/redis-lifecycle-design.md` 中说明 ClusterIP 不用于 replica-announce 的原因
- [x] 1.3 更新 `docs/research/koda-vs-kubeblocks-redis-service-announce-env-var.md` 的结论，反映当前设计选择

## 2. scripts/init.sh 实现

- [x] 2.1 新增 `resolve_announce_addr()` 函数，支持 Headless 回退与 HostNetwork 分支，并预留 per-pod NodePort/LB 解析点
- [x] 2.2 在 `init.sh server` 首次创建时生成 `redis-runtime.conf`，并加入 `include /data/redis-announce.conf`
- [x] 2.3 在 `init.sh server` 运行时生成或覆盖 `/data/redis-announce.conf`
- [x] 2.4 在 Pod 重建（`redis-runtime.conf` 已存在）且 Sentinel 启用时，查询 Sentinel 获取当前 master
- [x] 2.5 根据 Sentinel 返回结果原地更新 `redis-runtime.conf` 中的 `replicaof` 行（或移除）
- [x] 2.6 定义并读取新环境变量：`KODA_SENTINEL_HEADLESS_SERVICE`、`SENTINEL_PORT`、可选 `SENTINEL_ENABLED`

## 3. ComponentDefinition 设计

- [x] 3.1 设计 `redis-server` 容器的环境变量：固定 `REDIS_PORT=6379`、`REDIS_HOST_NETWORK_PORT`（`hostNetworkFieldRef`）
- [x] 3.2 设计 Sentinel 相关环境变量注入方式，确保 `init.sh` 能定位 Sentinel 端点
- [x] 3.3 声明可选的共享 ClusterIP Service（仅用于集群内客户端访问，不用于 announce）
- [x] 3.4 预留 per-pod NodePort / LoadBalancer Service 契约，标注为当前 Koda 控制面 pending 能力

## 4. 测试（当前可执行）

- [x] 4.1 在 `tests/unit/scripts/init.test.sh` 中新增 announce 配置生成测试（Headless 回退、HostNetwork）
- [x] 4.2 新增单元测试：Pod 重建时 `redis-announce.conf` 被覆盖而 `redis-runtime.conf` 其他内容不变
- [x] 4.3 新增单元测试：Sentinel 查询失败与成功分支
- [x] 4.4 新增单元测试：per-pod NodePort / LoadBalancer 环境变量解析与 ordinal 匹配逻辑（通过 mock `REDIS_ADVERTISED_PORT` / `REDIS_LB_ADVERTISED_HOST` 验证脚本可扩展性）
- [x] 4.5 更新或新增 E2E 用例，验证 Sentinel 故障转移后旧 master Pod 重建能正确恢复为 replica
- [ ] 4.6（可选）在现有 K8s 集群中创建临时 `hostNetwork: true` Pod，验证 `init.sh` 在 hostNetwork 环境下能正确拿到 Node IP 并生成 announce

## 5. 测试与未来能力（阻塞项）

- [ ] 5.1 per-pod NodePort Service 的完整 Koda E2E 测试 —— 阻塞：Koda `podService: true` 尚未实际创建 per-pod Service
- [ ] 5.2 per-pod LoadBalancer Service 的完整 Koda E2E 测试 —— 阻塞：Koda `serviceFieldRef` 不支持 per-pod Service 聚合
- [ ] 5.3 HostNetwork 模式下 `hostNetworkFieldRef` 自动注入 `REDIS_HOST_NETWORK_PORT` 的 Koda E2E 测试 —— 阻塞：当前集群未安装 Koda 控制面
