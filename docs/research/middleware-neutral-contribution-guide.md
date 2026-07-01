# 中间件开发者可为 Koda 贡献的中立资源指南

> 视角：熟悉 Redis 等中间件、但对 Koda 平台不了解的开发者  
> 目的：从第一性原理出发，识别贡献一个 Koda AppPack 时**最核心、不可缺少**的中立资源

---

## 核心结论

对 Koda 不了解的中间件开发者，可以独立贡献一个 AppPack 的**核心运行时资产**。这些资产是平台无关的，且缺了任何一个，AppPack 都无法真正运行 Redis。

Koda 集成者只需把这些资产映射到 Koda 的 CRD 结构中。

---

## 第一性原理：AppPack 安装后必须回答四个问题

Koda 平台运行 Redis，本质上需要回答：

1. **用什么跑？** → 镜像
2. **按什么配置跑？** → 配置模板
3. **怎么做高可用运维？** → 生命周期脚本
4. **怎么打包交付？** → Helm Chart 基础模板

其他内容（详细文档、测试数据、构建脚本、性能调优手册）都属于锦上添花，可以在核心资产就绪后补充。

---

## 不可缺少的中立资源

### 1. 容器镜像

没有镜像，就没有可运行的 Redis。

| 镜像 | 作用 |
|---|---|
| 主引擎镜像 | 运行 Redis 进程 |
| 监控导出镜像 | 暴露 Redis 指标 |
| 运维工具镜像 | 执行角色探测、切换、扩缩容等动作 |
| 初始化/备份恢复镜像 | 数据目录初始化、备份、恢复 |

**为什么不可缺少**：镜像是运行时唯一入口，Koda 无法替代。

---

### 2. 配置模板

没有配置，Redis 无法按预期行为运行。

| 配置 | 作用 |
|---|---|
| `redis.conf` | Redis 核心运行配置 |
| `sentinel.conf` | Sentinel 模式配置 |
| `cluster.conf` / 集群相关配置 | Cluster 模式配置 |

**为什么不可缺少**：不同拓扑（standalone、replication、cluster、sentinel）需要不同的配置，这是 Redis 本身的领域知识，平台无法凭空生成。

---

### 3. 生命周期动作脚本

没有脚本，Koda 无法完成有状态中间件的关键运维动作。

| 脚本 | 作用 |
|---|---|
| `roleProbe` | 探测实例当前角色 |
| `availableProbe` | 检查实例是否可用 |
| `switchover` | 执行主从切换 |
| `memberJoin` | 新成员加入集群 |
| `memberLeave` | 成员退出集群 |
| `reconfigure` | 热加载配置 |
| `accountProvision` | 创建/删除账号 |

**为什么不可缺少**：Koda 只负责编排动作调用，动作本身如何实现完全依赖 Redis 运维脚本。脚本质量直接决定高可用能力。

---

### 4. Helm Chart 基础模板

没有 Chart，Koda 无法把上述资产安装进平台。

| Chart 组成部分 | 作用 |
|---|---|
| `Chart.yaml` | Chart 元数据 |
| `values.yaml` | 默认参数 |
| `_helpers.tpl` | 通用模板函数 |
| ConfigMap/Secret 模板 | 渲染配置、密码、TLS |
| Service 模板 | 暴露服务 |

**为什么不可缺少**：AppPack 当前只支持 Helm 类型，Chart 是唯一的交付载体。

---

## 相对次后的内容（可后续补充）

以下资源虽然有价值，但不影响 AppPack 是否能跑起来：

- 详细用户文档
- 性能调优指南
- 测试数据与基准测试
- 构建脚本
- 备份恢复之外的扩展运维脚本
- 多架构镜像优化

---

## 协作边界

| 中间件开发者 | Koda 集成者 |
|---|---|
| 提供镜像、配置模板、生命周期脚本、Chart 基础模板 | 把上述资产映射为 ComponentDefinition、ApplicationDefinition、ComponentMatrix、AppPack CR |

---

## 一句话总结

**中间件开发者最核心、不可缺少的贡献是：镜像、配置、脚本、Chart 基础模板。有了这四样，Koda 就能把它组装成一个可运行的 Redis AppPack。**
