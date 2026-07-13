# koda-apppack Redis 测试环境安装与配置调研

## 目标

本文档说明如何在本地（以 Kind 为主）搭建可用于测试 koda-apppack Redis 的完整环境，包括：

1. Koda 控制面的安装与就绪检查。
2. Redis AppPack 的构建、打包与安装。
3. 通过 `Application` 创建 Redis replication + Sentinel 运行时实例。
4. 验证运行时资源（Component、StatefulGroup、Pod、Service、Secret 等）成功收敛。

> 当前 Koda 代码已支持 AppPack 作为定义层安装入口，但 **koda-apppack 仓库尚无 `charts/redis-pack/` Helm Chart**，因此搭建测试环境的前提是先补齐该 Chart。

---

## 前置条件

| 依赖 | 版本/说明 | 用途 |
|---|---|---|
| Go | 1.25+ | 编译 Koda manager / agent |
| Docker | 支持 BuildKit | 构建镜像 |
| kind | v0.24+（Koda Makefile 自动下载） | 本地 K8s 集群 |
| kubectl | 与 kind 集群版本兼容 | 资源操作 |
| Helm | 3.13+ | 安装 Koda Helm chart / AppPack 内部 Helm runner |
| cert-manager | v1.20.2（可选，Koda e2e 自动安装） | Koda webhook 证书注入 |
| 网络 | 可拉取 `quay.io/jetstack/cert-manager-*`、`kindest/node:v1.35.0` 等镜像 | 首次运行需联网 |

Koda e2e 默认使用 **Kubernetes v1.35.0**：

```bash
KIND_NODE_IMAGE=kindest/node:v1.35.0
```

---

## Koda 控制面安装

Koda 支持两种安装方式，测试时推荐用 kustomize（`config/default`），因为它与当前 e2e 流程一致；Helm chart 方式用于验证产品化安装路径。

### 方式一：kustomize（推荐用于开发/调试）

```bash
cd /path/to/kubesphere-extensions/koda

# 1. 创建 kind 集群（如不存在）
make setup-test-e2e

# 2. 构建 manager / agent 镜像并加载到 kind
make docker-build IMG=example.com/koda:v0.0.1-test
make agent-docker-build AGENT_IMG=example.com/koda-agent:v0.0.1-test
kind load docker-image example.com/koda:v0.0.1-test --name koda-test-e2e
kind load docker-image example.com/koda-agent:v0.0.1-test --name koda-test-e2e

# 3. 创建 namespace 并安装 CRDs
kubectl create ns koda-system
kubectl label --overwrite ns koda-system pod-security.kubernetes.io/enforce=restricted
make install

# 4. 部署 controller（会自动替换 config/default 中的 agent 镜像）
make deploy IMG=example.com/koda:v0.0.1-test AGENT_IMG=example.com/koda-agent:v0.0.1-test
```

> `config/default` 默认启用 webhook 与 cert-manager，因此步骤 4 前必须确保证书注入完成，否则 mutating/validating webhook 无法就绪。

就绪检查：

```bash
kubectl wait deployment/koda-controller-manager -n koda-system --for=condition=Available --timeout=120s
kubectl get mutatingwebhookconfigurations koda-mutating-webhook-configuration -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | wc -c
kubectl get validatingwebhookconfigurations koda-validating-webhook-configuration -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | wc -c
```

### 方式二：Helm chart（验证产品化安装）

```bash
cd /path/to/kubesphere-extensions/koda
helm upgrade --install koda charts/koda \
  --namespace koda-system \
  --create-namespace \
  --set namespace.create=false \
  --set image.registry=example.com \
  --set image.repository=koda \
  --set image.tag=v0.0.1-test \
  --set agent.image.registry=example.com \
  --set agent.image.repository=koda-agent \
  --set agent.image.tag=v0.0.1-test
```

> Helm chart 方式同样需要 cert-manager；如要跳过，设置 `--set webhook.enabled=false`，但会关闭 admission webhook，不推荐用于测试 Redis 业务链路。

---

## Redis AppPack 构建与安装

koda-apppack 仓库当前缺少 `charts/redis-pack/`，因此测试前必须先完成该 Chart。参考 Koda MySQL AppPack 测试用例的结构：

```text
koda-apppack/
└── charts/redis-pack/
    ├── Chart.yaml
    ├── values.yaml
    ├── Dockerfile          # 构建 chart image
    └── templates/
        ├── _helpers.tpl
        ├── applicationdefinition.yaml
        ├── componentdefinition.yaml      # redis-server / redis-sentinel / redis-exporter
        ├── componentmatrix.yaml
        ├── configfiledefinition.yaml
        └── configmap.yaml                # 模板与脚本 ConfigMap
```

### 1. 编写 Chart

Chart 需渲染以下定义层资源：

- `ApplicationDefinition`：暴露 `replication-sentinel` 拓扑。
- `ComponentDefinition`：`redis-server`、`redis-sentinel`、`redis-exporter`。
- `ComponentMatrix`：版本矩阵，例如 `7.2.4`，并映射各容器镜像。
- `ConfigFileDefinition`：Redis / Sentinel 配置参数 Schema。
- ConfigMap：只读配置模板、生命周期脚本。

关键约束：

- `Chart.yaml` 的 `appVersion` 前缀必须能在 `ComponentMatrix.releases[].engineVersion` 中匹配。
- `ComponentMatrix.images` 的 key 必须覆盖对应 `ComponentDefinition` 中所有 `containers[].name` 和 `initContainers[].name`。
- `ComponentDefinition` 中引用模板/脚本 ConfigMap 时，必须显式写 release namespace（`koda-system`），因为 AppPack install Job 在该 namespace 运行。

### 2. 构建 Chart Image

参考 Koda MySQL 测试：

```dockerfile
FROM busybox:1.36
COPY . /charts/redis
```

```bash
cd /path/to/koda-apppack/charts/redis-pack
docker build -t example.com/koda-redis-pack:v0.0.1-test -f Dockerfile .
kind load docker-image example.com/koda-redis-pack:v0.0.1-test --name koda-test-e2e
```

### 3. 创建 AppPack CR

```yaml
apiVersion: extensions.koda.io/v1alpha1
kind: AppPack
metadata:
  name: redis-7
  namespace: koda-system
spec:
  type: Helm
  installable:
    autoInstall: true
  helm:
    chartLocationURL: file:///charts/redis
    chartsImage: example.com/koda-redis-pack:v0.0.1-test
    chartsPathInImage: /charts
```

安装后 Koda 会创建一个 install Job，该 Job 使用 ServiceAccount `apppack-helm-runner`（已随 `config/default` 部署）执行 Helm install。

### 4. 等待 AppPack 就绪

```bash
# 等待 install Job 出现
kubectl get job redis-7-install -n koda-system

# 等待 AppPack phase 变为 Enabled
kubectl wait apppack redis-7 -n koda-system --for=jsonpath='{.status.phase}=Enabled' --timeout=300s
```

需确认的资源：

```bash
kubectl get applicationdefinition redis
kubectl get componentdefinition redis-server redis-sentinel redis-exporter
kubectl get componentmatrix redis-7
kubectl get configfiledefinition redis-config
kubectl get configmap -n koda-system | grep redis
```

---

## 创建 Redis 运行时实例

AppPack 安装的是**能力包**（定义层资源），租户实例需要单独创建 `Application`。

### 1. 创建 workload namespace

```bash
kubectl create ns koda-e2e-redis
kubectl label --overwrite ns koda-e2e-redis pod-security.kubernetes.io/enforce=restricted
```

### 2. 创建 Application

示例（replication + sentinel，1 主 2 从 3 sentinel）：

```yaml
apiVersion: core.koda.io/v1alpha1
kind: Application
metadata:
  name: e2e-redis
  namespace: koda-e2e-redis
spec:
  definitionRef: redis
  topology: replication-sentinel
  components:
  - name: redis-server
    engineVersion: "7.2"
    replicas: 3
    persistence:
      volumeClaims:
      - name: data
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 1Gi
      retentionPolicy:
        whenDeleted: Delete
        whenScaled: Delete
    security:
      systemAccounts:
      - name: default
        passwordPolicy:
          length: 16
          numDigits: 2
          numSymbols: 1
      - name: replication
        passwordPolicy:
          length: 16
          numDigits: 2
          numSymbols: 1
  - name: redis-sentinel
    engineVersion: "7.2"
    replicas: 3
    persistence:
      volumeClaims:
      - name: data
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 100Mi
      retentionPolicy:
        whenDeleted: Delete
        whenScaled: Delete
  policies:
  - termination:
      policy: Delete
```

### 3. 等待运行时收敛

```bash
# Component 就绪
kubectl wait component e2e-redis-redis-server -n koda-e2e-redis --for=condition=Ready --timeout=300s

# StatefulGroup / StatefulInstance 就绪
kubectl wait statefulgroup e2e-redis-redis-server -n koda-e2e-redis --for=condition=Ready --timeout=300s
kubectl get statefulinstance -n koda-e2e-redis

# Pod 就绪
kubectl wait pod -n koda-e2e-redis -l core.koda.io/component=e2e-redis-redis-server --for=condition=Ready --timeout=300s
```

### 4. 验证服务发现与账号

```bash
# 账号 Secret
kubectl get secret -n koda-e2e-redis | grep account

# 导出的 Service（如 mysql 中的 writer service）
kubectl get service -n koda-e2e-redis

# 进入 redis-server 主节点验证
kubectl exec -n koda-e2e-redis e2e-redis-redis-server-0 -- redis-cli -a $(kubectl get secret e2e-redis-redis-server-account-default -n koda-e2e-redis -o jsonpath='{.data.password}' | base64 -d) INFO replication
```

---

## 镜像清单

手动搭建测试环境时，需要确保以下镜像可被 kind 集群访问：

| 镜像 | 来源 | 说明 |
|---|---|---|
| `example.com/koda:v0.0.1-test` | 本地构建并 load | Koda controller manager |
| `example.com/koda-agent:v0.0.1-test` | 本地构建并 load | Koda agent sidecar |
| `example.com/koda-redis-pack:v0.0.1-test` | 本地构建并 load | Redis AppPack chart image |
| `redis:7.2.4`（或对应版本） | 拉取并 load | redis-server / sentinel 运行时 |
| `alpine/helm:3.13.3` | 拉取并 load | AppPack install Job 中的 Helm runner |
| `busybox:1.36` | 拉取并 load | chart image 基础镜像 / copy-chart initContainer |
| `quay.io/jetstack/cert-manager-*:v1.20.2` | 网络拉取或预加载 | webhook 证书管理 |

---

## Makefile 目标参考

Koda 仓库提供以下 e2e 相关 target，可直接用于启动环境：

```bash
# 创建 kind 集群
make setup-test-e2e

# 运行全部 e2e（会自动构建/加载镜像、安装 cert-manager、部署 Koda）
make test-e2e

# 仅运行 MySQL topology e2e（Redis 测试可仿照新增 scope）
make test-e2e-mysql-topology

# 清理 kind 集群
make cleanup-test-e2e
```

对于 koda-apppack Redis，建议新增类似的 Makefile target，例如：

```bash
make test-e2e-redis
```

该 target 应：

1. 复用 Koda 的 kind 集群或独立创建。
2. 构建并加载 Redis chart image、运行时 Redis 镜像。
3. 创建 `AppPack` 并等待 `Enabled`。
4. 创建 `Application` 并验证运行时收敛。

---

## 已知阻塞点

1. **缺少 `charts/redis-pack/`**
   - 必须先完成 Redis AppPack Helm Chart，否则无法创建 AppPack。

2. **Koda 未实现 `podService`**
   - 如果 Redis 需要 per-pod NodePort / LoadBalancer 服务做外部发现，当前 Koda 不支持。
   - replication + Sentinel 内部发现可依赖 headless service + `componentFieldRef.podFQDNs`，不需要 `podService`。

3. **Sentinel 对 redis-server 的跨组件引用**
   - 需要在 `ApplicationDefinition` 的 topology 中正确声明组件依赖，使 Sentinel Component 能拿到 redis-server 的 Pod FQDN 列表。

4. **脚本权限与脚本投影**
   - Koda 当前要求脚本通过 `ComponentDefinition.spec.runtime.assets.scripts[]` 声明，由 Component controller 投影到 workload namespace。
   - 脚本 ConfigMap 需设置 `defaultMode: 0555`，确保 init 容器可执行。

---

## 推荐的最小可复现步骤

```bash
# 1. 准备 Koda 代码
cd /path/to/kubesphere-extensions/koda
make setup-test-e2e

# 2. 构建并加载 Koda 镜像
make docker-build IMG=example.com/koda:v0.0.1-test
make agent-docker-build AGENT_IMG=example.com/koda-agent:v0.0.1-test
kind load docker-image example.com/koda:v0.0.1-test --name koda-test-e2e
kind load docker-image example.com/koda-agent:v0.0.1-test --name koda-test-e2e

# 3. 安装 Koda
kubectl create ns koda-system
make install
make deploy IMG=example.com/koda:v0.0.1-test AGENT_IMG=example.com/koda-agent:v0.0.1-test
kubectl wait deployment/koda-controller-manager -n koda-system --for=condition=Available --timeout=120s

# 4. 构建并安装 Redis AppPack（假设 chart 已存在）
cd /path/to/koda-apppack/charts/redis-pack
docker build -t example.com/koda-redis-pack:v0.0.1-test -f Dockerfile .
kind load docker-image example.com/koda-redis-pack:v0.0.1-test --name koda-test-e2e
kubectl apply -f - <<EOF
apiVersion: extensions.koda.io/v1alpha1
kind: AppPack
metadata:
  name: redis-7
  namespace: koda-system
spec:
  type: Helm
  installable:
    autoInstall: true
  helm:
    chartLocationURL: file:///charts/redis
    chartsImage: example.com/koda-redis-pack:v0.0.1-test
    chartsPathInImage: /charts
EOF
kubectl wait apppack redis-7 -n koda-system --for=jsonpath='{.status.phase}=Enabled' --timeout=300s

# 5. 创建 Redis Application
kubectl create ns koda-e2e-redis
kubectl apply -f /path/to/koda-apppack/tests/e2e/redis-application.yaml
kubectl wait component e2e-redis-redis-server -n koda-e2e-redis --for=condition=Ready --timeout=300s
```

---

## 参考

- Koda `Makefile`：`test-e2e`、`setup-test-e2e`、`docker-build`、`agent-docker-build` 目标。
- Koda e2e suite：`/test/e2e/e2e_suite_test.go`、`/test/e2e/e2e_test.go`、`/test/e2e/mysql_topology_test.go`。
- Koda AppPack 设计：`/docs/superpowers/specs/apppack/2026-05-20-apppack-crd-design.md`。
- Koda AppPack-backed MySQL E2E 设计：`/docs/superpowers/specs/apppack/2026-07-08-apppack-backed-mysql-e2e-design.md`。
- koda-apppack 设计：`/docs/design/redis-koda-contract-design.md`。
