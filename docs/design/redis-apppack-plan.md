# Koda Redis AppPack 开发计划

> 调研范围：`/root/.local/share/opencode/repos/github.com/kubesphere-extensions/koda`  
> 目标中间件：Redis  
> 视角：AppPack 开发者  
> 文档性质：宏观规划，明确“做什么”与“顺序”，不涉及具体脚本与代码

---

## 1. 背景与角色定位

### 1.1 项目关系

`/mnt/vol-yrf9i817/koda-apppack` 是当前工作目录，但 Koda 主项目代码位于引用目录：

- `/root/.local/share/opencode/repos/github.com/kubesphere-extensions/koda`

Koda 是一个基于 Kubernetes 的云原生数据库与中间件平台。其核心控制平面包含：

- `AppPack`：平台能力包安装层
- `ApplicationDefinition` / `ComponentDefinition`：定义层资产
- `ComponentMatrix`：版本矩阵
- `StatefulGroup` / `StatefulInstance`：有状态运行时层
- `OpsTask` / `ComponentParameter`：运维与参数治理

### 1.2 AppPack 的角色

AppPack 对应上游 KubeBlocks 的 Addon 概念，是**平台能力安装层**，负责把数据库/中间件能力包安装进平台，生成静态定义资产，**不直接创建租户的数据库实例**。

```text
用户创建/启用 AppPack
      ↓
Webhook 静态校验
      ↓
Controller 深度校验（engine version、image key）
      ↓
Controller 创建 Install/Upgrade/Uninstall Job
      ↓
Helm install/upgrade/uninstall 渲染 Chart
      ↓
生成 ApplicationDefinition、ComponentDefinition、ComponentMatrix 等资产
      ↓
租户运行时 Application/Component 引用这些资产
```

### 1.3 AppPack 开发者职责边界

| 角色 | 职责 |
|---|---|
| Koda 核心开发者 | 维护 AppPack CRD、Controller、Webhook、Job 编排、深度校验逻辑 |
| AppPack 开发者（本计划视角） | 为 Redis 准备并交付可安装的 Helm Chart 及静态定义资产 |

---

## 2. 总体目标

为 Koda 平台交付一个 **Redis AppPack**，使其能够通过 Koda 的 AppPack 机制完成安装、升级、禁用，并向平台提供 Redis 能力定义资产。

---

## 3. 开发阶段与顺序

### 阶段一：需求与规格定义

**目标**：明确 Redis 能力包“提供什么”。

| 序号 | 工作项 | 说明 |
|---|---|---|
| 1.1 | 确定支持的拓扑形态 | 例如 standalone、replication、cluster、sentinel |
| 1.2 | 确定支持的 Redis 版本 | 例如 7.0、7.2，作为 ComponentMatrix 的 engineVersion |
| 1.3 | 拆分组件 | 例如 redis-server、redis-sentinel、redis-exporter、proxy |
| 1.4 | 定义运行时资源需求 | CPU、内存、存储、PVC、端口、安全上下文、RBAC |
| 1.5 | 定义 Day2 运维能力 | roleProbe、availableProbe、switchover、memberJoin、memberLeave、reconfigure 等 |
| 1.6 | 明确依赖与约束 | 外部服务依赖、与其他能力包的关系、安装前提 |

**阶段产出**：

- Redis AppPack 能力规格文档

---

### 阶段二：Chart 与静态资产准备

**目标**：准备一个 Helm Chart，安装后能渲染出 Koda 平台可识别的静态定义资产。

| 序号 | 工作项 | 说明 |
|---|---|---|
| 2.1 | 设计 Chart 元数据 | 确定 Chart 名称、版本、appVersion、描述、类型 |
| 2.2 | 编写 ComponentDefinition 模板 | 为每个组件定义运行时模型、生命周期动作、服务契约、存储、配置、凭证 |
| 2.3 | 编写 ApplicationDefinition 模板 | 定义支持的拓扑，以及拓扑中各 slot 引用的 ComponentDefinition |
| 2.4 | 编写 ComponentMatrix 模板 | 定义版本矩阵、兼容规则、镜像映射 |
| 2.5 | 准备配置与脚本模板 | Redis 配置文件、启动脚本、运维动作脚本，作为 ConfigMap / ConfigFileDefinition |
| 2.6 | 设计容器与镜像 key | ComponentDefinition 中的 containers/initContainers 名称需与 ComponentMatrix.images key 对应 |
| 2.7 | 设计服务与凭证契约 | headless/cluster/nodeport/lb 服务、系统账号、密码策略、TLS 模式 |

**关键约束**：

- `ComponentMatrix.images` 的 key 必须覆盖对应 `ComponentDefinition` 中所有 `containers[].name` 和 `initContainers[].name`
- `Chart.appVersion` 前缀必须能在 `ComponentMatrix.releases[].engineVersion` 中匹配

**阶段产出**：

- Redis Helm Chart
- Chart 渲染出的 ComponentDefinition(s)
- Chart 渲染出的 ApplicationDefinition
- Chart 渲染出的 ComponentMatrix
- 配置模板与脚本模板

---

### 阶段三：安装参数与平台适配设计

**目标**：设计平台标准化参数到 Chart values 的映射，以及不同环境下的默认参数。

| 序号 | 工作项 | 说明 |
|---|---|---|
| 3.1 | 设计 valuesMapping | 平台通用字段到 Helm values 键的映射 |
| 3.2 | 设计标量字段映射 | replicas、storageClass、persistentVolumeEnabled |
| 3.3 | 设计资源字段映射 | cpu.requests/limits、memory.requests/limits、storage |
| 3.4 | 设计 JSON 字段映射 | tolerations |
| 3.5 | 设计扩展组件映射 | extras，如 proxy.replicas、exporter.enabled |
| 3.6 | 设计 defaultInstallValues | 按环境提供默认参数，遵循 First Match Wins |
| 3.7 | 设计 install 用户覆盖参数 | 用户可显式覆盖的参数 |
| 3.8 | 设计 installable 约束 | K8s 版本范围、云厂商限制、是否自动安装 |

**阶段产出**：

- valuesMapping 定义
- defaultInstallValues 多环境默认值
- install 用户覆盖参数说明
- installable 安装约束

---

### 阶段四：校验与验证

**目标**：确保 Chart 与 Koda 平台契约一致，安装/升级/卸载流程正常。

| 序号 | 工作项 | 说明 |
|---|---|---|
| 4.1 | Chart 渲染验证 | 确认模板能正常渲染，YAML 无语法错误 |
| 4.2 | 定义资产 Schema 校验 | 确认渲染结果符合 Koda CRD 结构 |
| 4.3 | AppPack CR 自洽性校验 | type、helm、defaultInstallValues、selector 重叠、valuesMapping 一致性 |
| 4.4 | Engine Version 匹配校验 | Chart.appVersion 前缀与 ComponentMatrix.engineVersion 匹配 |
| 4.5 | Image Key 完整性校验 | ComponentMatrix.images 覆盖所有容器名 |
| 4.6 | 安装流程验证 | 安装 Job 成功，phase 流转 Disabled → Enabling → Enabled |
| 4.7 | 升级流程验证 | spec 更新触发 Upgrade Job，已有实例不受影响 |
| 4.8 | 禁用/卸载流程验证 | Disabling → Disabled/Uninstall Job 成功清理资产 |
| 4.9 | 失败重试验证 | 失败进入 Failed，支持 retry annotation 重试 |

**阶段产出**：

- 校验报告
- 问题清单与修复记录

---

### 阶段五：打包与发布

**目标**：把能力包交付到可安装的位置，并提供元数据与文档。

| 序号 | 工作项 | 说明 |
|---|---|---|
| 5.1 | Chart 版本管理 | Chart.version 管理 definition 迭代，appVersion 管理引擎版本 |
| 5.2 | 镜像版本管理 | 确保镜像 tag 明确、可追溯、支持多架构 |
| 5.3 | Chart 打包 | 生成 Helm Chart 包 |
| 5.4 | Chart 推送到仓库 | 优先推送到 OCI 仓库 |
| 5.5 | 准备 AppPack CR 描述 | chartLocationURL、version、valuesMapping、defaultInstallValues、installable |
| 5.6 | 编写用户文档 | 安装说明、拓扑说明、参数说明、升级/回退策略、已知限制 |
| 5.7 | 编写变更说明 | 每个版本更新内容、兼容性说明 |

**阶段产出**：

- 已发布到 OCI/Helm 仓库的 Chart
- AppPack CR 描述文件
- 用户文档与变更日志

---

### 阶段六：平台接入与持续迭代

**目标**：在 Koda 平台注册并持续维护 Redis AppPack。

| 序号 | 工作项 | 说明 |
|---|---|---|
| 6.1 | 在 Koda 平台注册 AppPack | 创建/启用 AppPack，触发 Webhook 与 Controller 校验 |
| 6.2 | 多环境适配验证 | 验证 defaultInstallValues 在不同云厂商/K8s 版本下的自动匹配 |
| 6.3 | 插件修复迭代 | 只升级 Chart 版本，修复 definition/脚本/模板问题 |
| 6.4 | 引擎版本升级 | 在 ComponentMatrix 中新增 release 条目 |
| 6.5 | 双升级迭代 | 同时更新 Chart 和 ComponentMatrix |
| 6.6 | release 废弃管理 | 旧 release 标记 deprecated，无实例引用后再移除 |
| 6.7 | 问题响应与回退 | 处理安装失败、校验失败、运行时兼容性问题 |

**阶段产出**：

- 平台上已启用的 Redis AppPack
- 持续维护的版本矩阵
- 升级与回退记录

---

## 4. 关键顺序依赖

1. **规格定义 → 组件拆分与版本设计**：必须先明确拓扑与组件，才能确定 ComponentDefinition 数量。
2. **ComponentDefinition 容器命名 → ComponentMatrix images key 设计**：容器名必须被镜像矩阵覆盖。
3. **Chart values 结构设计 → valuesMapping 设计**：valuesMapping 必须基于 Chart 实际 values 路径。
4. **Chart 与静态资产完成 → 平台注册安装**：AppPack CR 必须指向可用的 Chart。
5. **本地校验通过 → 推送仓库与发布**：避免平台安装直接进入 Failed 状态。
6. **ComponentMatrix release 更新 → Chart 与 AppPack CR 更新**：版本矩阵变更应领先或同步于 Chart 发布。

---

## 5. 命名规范建议

| 对象 | 命名规范 | 示例 |
|---|---|---|
| AppPack | `{引擎名}-{主版本标识}` | `redis-7` |
| ComponentMatrix | `{引擎名}-{主版本标识}` | `redis-7` |
| ComponentDefinition | 组件语义名 | `redis-server`、`redis-sentinel`、`redis-exporter` |
| ApplicationDefinition | 应用族语义名 | `redis` |
| Chart | 插件语义名 | `redis-pack` |
| Release name | `{engineVersion}-{build}` | `7.2.4-v1.0.0` |

---

## 6. 主要参考文件

| 文件路径 | 用途 |
|---|---|
| `knowledge/project-design/apppack设计.md` | AppPack 生命周期、状态机、校验规则 |
| `docs/superpowers/specs/apppack/2026-05-20-apppack-crd-design.md` | AppPack CRD 顶层设计 |
| `api/extensions/v1alpha1/apppack_types.go` | AppPack API 类型定义 |
| `api/definitions/v1alpha1/definitions_types.go` | ComponentDefinition、ApplicationDefinition、ComponentMatrix 类型 |
| `knowledge/project-design/组件版本治理设计.md` | ComponentMatrix 版本治理规则 |
| `test/e2e/testdata/controller-chain/componentdefinition.yaml` | ComponentDefinition 完整示例 |
| `AGENTS.md` | Koda 项目开发规范与流程 |

---

## 7. 风险与注意事项

1. **版本一致性风险**：Chart.appVersion 与 ComponentMatrix.engineVersion 必须匹配，否则平台深度校验会失败。
2. **镜像 key 缺失风险**：ComponentMatrix.images 必须覆盖 ComponentDefinition 中所有容器名。
3. **环境适配风险**：defaultInstallValues 的 selector 设计不当会导致某些环境无法安装或参数不匹配。
4. **升级可用性风险**：Upgrade Job 应确保不删除已有 ApplicationDefinition/ComponentDefinition，避免影响存量实例。
5. **卸载残留风险**：Uninstall Job 必须完整清理 Chart 渲染出的静态资产，否则可能导致重复安装或资源泄漏。

---

## 8. 下一步建议

1. 审阅本计划，确认 Redis 的拓扑形态、支持版本、组件拆分是否符合预期。
2. 如需细化，可进入阶段二（Chart 与静态资产准备）的详细设计。
3. 确认后，开始编写 Redis AppPack 的能力规格文档与 Chart 结构。
