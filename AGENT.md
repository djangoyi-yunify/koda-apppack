## 项目简介

根据 [Koda](https://github.com/kubesphere-extensions/koda) 项目对 AppPack 的定义，制作可被 Koda 控制面使用的 Redis AppPack。

本仓库为 **Redis 专属 AppPack 交付仓库**，目标是通过 Koda 的 AppPack 机制把 Redis 能力包安装进平台，生成 `ComponentDefinition`、`ApplicationDefinition`、`ComponentMatrix` 等静态定义资产。AppPack 本身不直接创建租户的数据库实例。

## 目录组织

本仓库采用 **单仓库单 AppPack** 结构，Redis 相关的脚本、配置模板与 Helm Chart 分开放置：

```
koda-apppack/
├── charts/redis-pack/              # Helm Chart：平台安装入口
│   ├── Chart.yaml                  # Chart 元数据，appVersion 需匹配 ComponentMatrix.engineVersion
│   ├── values.yaml                 # 默认 Helm values
│   ├── templates/
│   │   ├── _helpers.tpl
│   │   ├── componentdefinition.yaml       # redis-server / redis-sentinel / redis-exporter 定义
│   │   ├── applicationdefinition.yaml     # Redis 拓扑定义
│   │   ├── componentmatrix.yaml           # 版本矩阵与镜像映射
│   │   ├── configmap.yaml                 # 只读配置模板
│   │   └── secret.yaml                    # 默认凭证模板
│   └── README.md
│
├── scripts/                        # Redis 生命周期动作脚本
│   ├── role-probe.sh
│   ├── available-probe.sh
│   ├── switchover.sh
│   ├── member-join.sh
│   ├── member-leave.sh
│   └── reconfigure.sh
│
├── configs/                        # Redis / Sentinel 配置模板
│   ├── redis-template.conf
│   ├── sentinel.conf
│   └── aclfile.tpl
│
├── tests/                          # 渲染测试与 Schema 校验
│   └── render-test.sh
│
├── docs/                           # 文档
│   ├── research/                   # 调研类文档：问题分析、上游研究、宏观 API 调研
│   │   ├── middleware-neutral-contribution-guide.md
│   │   ├── redis-config-persistence-analysis.md
│   │   └── statefulgroup-statefulinstance-macro.md
│   └── design/                     # 设计类文档：方案、计划、决策记录
│       └── redis-apppack-plan.md
│
├── hack/                           # 构建/打包辅助脚本
├── Makefile
├── README.md
└── AGENT.md
```

## 目标

第一阶段仅支持 **Redis replication + Sentinel** 这一种拓扑：

- 一主多从的 Redis 复制架构
- 一组 Sentinel 实例负责故障发现与自动切换
- 通过 Koda `StatefulGroup` / `StatefulInstance` 运行有状态工作负载

后续阶段再考虑 standalone、cluster 等其它拓扑。

## 交付物

1. **Helm Chart**（`charts/redis-pack/`）
   - 渲染 `ComponentDefinition`（redis-server、redis-sentinel、redis-exporter）
   - 渲染 `ApplicationDefinition`（replication + sentinel 拓扑）
   - 渲染 `ComponentMatrix`（版本、镜像、engineVersion 映射）

2. **生命周期脚本**（`scripts/`）
   - `role-probe`：探测实例角色
   - `available-probe`：检查实例可用性
   - `switchover`：执行主从切换
   - `member-join` / `member-leave`：集群成员变更
   - `reconfigure`：热加载配置

3. **配置模板**（`configs/`）
   - `redis-template.conf`：只读配置模板
   - `sentinel.conf`：Sentinel 配置模板
   - `aclfile.tpl`：ACL 规则模板

4. **文档与测试**
   - Chart 渲染测试
   - 安装/升级/卸载流程验证
   - 用户文档与参数说明

## 命名规范

| 对象 | 命名 | 说明 |
|---|---|---|
| AppPack | `redis-7` | 引擎名 + 主版本标识 |
| ComponentMatrix | `redis-7` | 与 AppPack 对应 |
| ApplicationDefinition | `redis` | 应用族语义名 |
| ComponentDefinition | `redis-server`、`redis-sentinel`、`redis-exporter` | 组件语义名 |
| Chart | `redis-pack` | 插件语义名 |
| Release | `{engineVersion}-{build}` | 例如 `7.2.4-v1.0.0` |

## 开发流程

1. 明确拓扑与组件拆分（已完成：replication + sentinel）
2. 设计 Chart 元数据、values 结构与模板
3. 编写 ComponentDefinition / ApplicationDefinition / ComponentMatrix 模板
4. 编写生命周期脚本与配置模板
5. 本地渲染验证：`helm template charts/redis-pack`
6. Schema 与契约校验
7. Koda 平台安装验证：`Disabled → Enabling → Enabled`
8. 升级/卸载流程验证

## 关键约束

- `Chart.appVersion` 前缀必须能在 `ComponentMatrix.releases[].engineVersion` 中匹配
- `ComponentMatrix.images` 的 key 必须覆盖对应 `ComponentDefinition` 中所有 `containers[].name` 和 `initContainers[].name`
- Redis 主配置文件（`redis-runtime.conf`、`sentinel.conf`）与 ACL 文件（`users.acl`）必须放在持久卷上，避免 Pod 重启后丢失角色、拓扑认知或 ACL 规则
- 只读配置模板通过 `include` 被主配置文件引用，且以只读方式挂载

## 技术标准

### Shell 脚本

本项目所有 Shell 脚本统一使用 **Bash**，以提高可维护性并充分利用数组、进程管理等特性：

- shebang 固定为 `#!/usr/bin/env bash`
- 开头启用严格模式：

  ```bash
  set -euo pipefail
  ```

- 需要跨平台或明确限制为 POSIX sh 的场景应单独说明并评审

## 参考文档

### 调研类（docs/research/）

- `docs/research/middleware-neutral-contribution-guide.md`：中间件开发者贡献边界调研
- `docs/research/redis-config-persistence-analysis.md`：Redis 配置文件持久化分析
- `docs/research/statefulgroup-statefulinstance-macro.md`：Koda 运行时层宏观调研

### 设计类（docs/design/）

- `docs/design/redis-apppack-plan.md`：Redis AppPack 宏观开发计划
- `docs/design/redis-lifecycle-design.md`：Redis 生命周期动作接口与 postProvision 设计

### 外部参考

- Koda 主项目 `docs/superpowers/specs/apppack/2026-05-20-apppack-crd-design.md`：AppPack CRD 顶层设计
