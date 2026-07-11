# kubeblocks-addons Redis 服务宣告机制调研

本文聚焦 kubeblocks-addons 中 Redis 组件如何通过 Kubernetes Service 与 Redis 配置配合，实现外部可访问的复制拓扑。分析范围覆盖 ComponentDefinition 声明、控制面环境变量构建、容器内脚本解析三个层面。

---

## 1. 核心设计思想

kubeblocks-addons Redis 采用**"容器内监听端口固定 + 外部访问地址动态宣告"**的设计：

- Redis 进程在容器内始终监听固定端口（默认 `6379`）。
- 外部访问入口通过 Kubernetes Service 提供，支持 ClusterIP、NodePort、LoadBalancer、HostNetwork 等多种模式。
- Redis 通过 `replica-announce-ip` 和 `replica-announce-port` 向客户端和其他副本宣告自己的外部可访问地址。
- 控制面将 Service 的运行时事实编码为环境变量，容器内脚本解析这些环境变量并生成对应的 `replica-announce-*` 配置。

```
┌─────────────────┐
│  ComponentDef   │  声明 service 契约（类型、端口、podService 等）
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  KubeBlocks     │  创建 Service，按类型构建环境变量
│  控制面          │  REDIS_ADVERTISED_PORT / REDIS_LB_ADVERTISED_HOST / REDIS_HOST_NETWORK_PORT
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  redis-start.sh │  解析环境变量，推导 replica-announce-ip/port
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   redis.conf    │  写入 replica-announce-ip / replica-announce-port
└─────────────────┘
```

---

## 2. 容器内端口策略

### 2.1 固定容器端口

在 `cmpd-redis.yaml` 中，Redis 容器端口固定声明为 `6379`：

```yaml
containers:
  - name: redis
    ports:
      - name: redis
        containerPort: 6379
```

### 2.2 服务端口变量

脚本中 `service_port` 默认也是 `6379`：

```bash
service_port=${SERVICE_PORT:-6379}
```

在 `build_redis_service_port()` 中，根据是否启用 TLS 写入：

```bash
if [ "$TLS_ENABLED" == "true" ]; then
  echo "tls-port $service_port" >> $redis_real_conf
else
  echo "port $service_port" >> $redis_real_conf
fi
```

这意味着：

- 容器进程始终监听 `6379`（或 TLS 模式下的等效端口）。
- 外部访问端口与内部监听端口可以不一致，依赖 Service 的 `targetPort` 映射。
- `replica-announce-port` 才是 Redis 对外宣告的访问端口。

---

## 3. Service 类型与声明

### 3.1 四种服务契约

`cmpd-redis.yaml` 中声明了以下服务：

| Service 名称 | 类型 | 用途 | 关键属性 |
|---|---|---|---|
| `redis` | ClusterIP | 集群内访问 | `roleSelector: primary`，仅指向主节点 |
| `redis-advertised` | NodePort | 外部访问（按 Pod） | `podService: true`，`disableAutoProvision: true` |
| `redis-lb-advertised` | LoadBalancer | 外部访问（按 Pod） | `podService: true`，`disableAutoProvision: true` |
| `redis-headless` | Headless | Pod DNS 发现 | 由 StatefulGroup/InstanceSet 自动创建 |

### 3.2 per-pod Service 设计

NodePort 和 LoadBalancer 类型的 Service 都开启了 `podService: true`：

```yaml
- name: redis-advertised
  serviceName: redis-advertised
  spec:
    type: NodePort
    ports:
      - name: redis-advertised
        port: 6379
        targetPort: redis
  podService: true
  disableAutoProvision: true
```

开启 `podService: true` 后，KubeBlocks 控制面会为每个 Pod 创建一个独立的 Service：

- Service 名字格式：`<cluster>-<component>-redis-advertised-<ordinal>`
- 每个 Service 的 selector 带有 `KBAppPodNameLabelKey: <podName>`，确保只路由到对应 Pod。
- `disableAutoProvision: true` 表示默认不自动创建，需要用户在 Cluster 的 `componentSpec.services` 中显式开启。

---

## 4. 控制面环境变量构建

### 4.1 注入到 Pod 的环境变量

`cmpd-redis.yaml` 的 `vars` 段通过 `serviceVarRef` 将 Service 信息注入为环境变量：

```yaml
vars:
  - name: REDIS_ADVERTISED_PORT
    valueFrom:
      serviceVarRef:
        name: redis-advertised
        optional: true
        port:
          name: redis-advertised
          option: Required

  - name: REDIS_LB_ADVERTISED_PORT
    valueFrom:
      serviceVarRef:
        name: redis-lb-advertised
        optional: true
        port:
          name: redis-advertised
          option: Required

  - name: REDIS_LB_ADVERTISED_HOST
    valueFrom:
      serviceVarRef:
        name: redis-lb-advertised
        optional: true
        loadBalancer: Required
        host: Required

  - name: REDIS_HOST_NETWORK_PORT
    valueFrom:
      hostNetworkVarRef:
        optional: true
        container:
          name: redis
          port:
            name: redis
            option: Required
```

### 4.2 环境变量值的格式

控制面在 `pkg/controller/component/vars.go` 中解析 `serviceVarRef`。当 `podService: true` 时，会把所有 per-pod Service 的信息聚合成逗号分隔的 `svcName:value` 字符串。

#### REDIS_ADVERTISED_PORT（NodePort）

```text
<cluster>-<component>-redis-advertised-0:<nodeport-0>,<cluster>-<component>-redis-advertised-1:<nodeport-1>,...
```

构建逻辑：

- 列出所有以 `<base-svc-name>-` 为前缀的 per-pod Service。
- 对每个 Service，找到名字匹配的 port。
- 如果 Service 类型为 NodePort，取 `spec.ports[].nodePort`；否则取 `spec.ports[].port`。
- 将所有 `svcName:port` 按 service 名字排序后用逗号连接。

#### REDIS_LB_ADVERTISED_PORT（LoadBalancer）

```text
<cluster>-<component>-redis-lb-advertised-0:6379,<cluster>-<component>-redis-lb-advertised-1:6379,...
```

#### REDIS_LB_ADVERTISED_HOST（LoadBalancer）

```text
<cluster>-<component>-redis-lb-advertised-0:<lb-ingress-0>,<cluster>-<component>-redis-lb-advertised-1:<lb-ingress-1>,...
```

构建逻辑：

- 因为同时声明了 `host` 和 `loadBalancer`，控制面走自适应逻辑。
- 当 Service 类型为 LoadBalancer 时，取 `status.loadBalancer.ingress[0]` 的 IP 或 hostname。
- 拼成 `svcName:lbIngress` 格式。

#### REDIS_HOST_NETWORK_PORT

单个数字，表示 HostNetwork 模式下为当前 Pod 分配的主机端口。

---

## 5. redis-start.sh 解析逻辑

### 5.1 入口函数

`parse_redis_announce_addr()` 是核心解析函数：

```bash
parse_redis_announce_addr() {
  if is_empty "$REDIS_ADVERTISED_PORT"; then
     REDIS_ADVERTISED_PORT="$REDIS_LB_ADVERTISED_PORT"
  fi

  if is_empty "${REDIS_ADVERTISED_PORT}"; then
    echo "Environment variable REDIS_ADVERTISED_PORT not found. Ignoring."
    if ! is_empty "${REDIS_HOST_NETWORK_PORT}"; then
      redis_announce_port_value="$REDIS_HOST_NETWORK_PORT"
      redis_announce_host_value="$CURRENT_POD_HOST_IP"
    fi
    return 0
  fi

  local pod_name="$1"
  local found=false
  pod_name_ordinal=$(extract_obj_ordinal "$pod_name")

  advertised_ports=($(split "$REDIS_ADVERTISED_PORT" ","))
  for advertised_port in "${advertised_ports[@]}"; do
    parts=($(split "$advertised_port" ":"))
    local svc_name="${parts[0]}"
    local port="${parts[1]}"
    svc_name_ordinal=$(extract_obj_ordinal "$svc_name")

    if [[ "$svc_name_ordinal" == "$pod_name_ordinal" ]]; then
      redis_announce_port_value="$port"
      lb_host=$(extract_lb_host_by_svc_name "$svc_name")
      if [ -n "$lb_host" ]; then
        redis_announce_host_value="$lb_host"
        redis_announce_port_value="6379"
      else
        redis_announce_host_value="$CURRENT_POD_HOST_IP"
      fi
      found=true
      break
    fi
  done

  if equals "$found" false; then
    echo "Error: No matching svcName and port found for podName '$podName'..."
    exit 1
  fi
}
```

### 5.2 决策优先级

```
parse_redis_announce_addr(CURRENT_POD_NAME)
        │
        ▼
REDIS_ADVERTISED_PORT 是否存在？
        │
        ├── 是 ──► 按 NodePort 逻辑解析
        │           （匹配当前 Pod ordinal 的 svc:port）
        │
        └── 否 ──► 回退到 REDIS_LB_ADVERTISED_PORT
                      │
                      ├── 如果存在 ──► 继续按 LB 逻辑解析
                      │                （再查 REDIS_LB_ADVERTISED_HOST 拿 LB host）
                      │
                      └── 如果不存在 ──► 检查 REDIS_HOST_NETWORK_PORT
                                           │
                                           ├── 存在 ──► 使用 Host IP + HostNetwork Port
                                           │
                                           └── 不存在 ──► 不设置 announce 值
```

### 5.3 Ordinal 匹配机制

脚本通过 `extract_obj_ordinal()` 从 Pod 名字和 Service 名字中提取 ordinal：

```bash
extract_obj_ordinal() {
  local object_name="$1"
  local ordinal="${object_name##*-}"
  echo "$ordinal"
}
```

例如：

- Pod 名 `mycluster-redis-0` → ordinal `0`
- Service 名 `mycluster-redis-redis-advertised-0` → ordinal `0`

通过 ordinal 相等来定位"属于当前 Pod"的那一项。

---

## 6. 不同 Service 类型的处理流程

### 6.1 NodePort 类型

```text
输入：
  REDIS_ADVERTISED_PORT = svc-0:30001,svc-1:30002

处理：
  - 提取当前 Pod ordinal
  - 找到匹配的 svc:port
  - redis_announce_host_value = CURRENT_POD_HOST_IP
  - redis_announce_port_value = 30001

输出到 redis.conf：
  replica-announce-ip   <node-ip>
  replica-announce-port 30001
```

### 6.2 LoadBalancer 类型

```text
输入：
  REDIS_LB_ADVERTISED_PORT = svc-0:6379,svc-1:6379
  REDIS_LB_ADVERTISED_HOST = svc-0:lb-0.example.com,svc-1:lb-1.example.com

处理：
  - REDIS_ADVERTISED_PORT 先回退到 REDIS_LB_ADVERTISED_PORT
  - 按 ordinal 匹配 svc
  - 调用 extract_lb_host_by_svc_name(svc) 获取 LB host
  - redis_announce_host_value = lb-0.example.com
  - redis_announce_port_value = 6379   # 硬编码覆盖

输出到 redis.conf：
  replica-announce-ip   lb-0.example.com
  replica-announce-port 6379
```

### 6.3 HostNetwork 类型

```text
输入：
  REDIS_HOST_NETWORK_PORT = <allocated-port>

处理：
  - redis_announce_host_value = CURRENT_POD_HOST_IP
  - redis_announce_port_value = REDIS_HOST_NETWORK_PORT

输出到 redis.conf：
  replica-announce-ip   <node-ip>
  replica-announce-port <allocated-port>
```

### 6.4 默认场景（无外部 Service）

当上述环境变量都不存在时，`redis_announce_host_value` 和 `redis_announce_port_value` 保持为空。后续 `build_announce_ip_and_port()` 按以下优先级处理：

```bash
if ! is_empty "$redis_announce_host_value" && ! is_empty "$redis_announce_port_value"; then
  # NodePort / LoadBalancer / HostNetwork 分支
  echo "replica-announce-port $redis_announce_port_value"
  echo "replica-announce-ip $redis_announce_host_value"
elif [ "$FIXED_POD_IP_ENABLED" == "true" ]; then
  # 固定 Pod IP 分支
  echo "replica-announce-ip $CURRENT_POD_IP"
else
  # 默认分支：使用 Pod FQDN
  current_pod_fqdn=$(get_target_pod_fqdn_from_pod_fqdn_vars ...)
  echo "replica-announce-ip $current_pod_fqdn"
fi
```

---

## 7. announce 配置与复制/Sentinel 的协作

### 7.1 复制关系建立

`build_replicaof_config()` 负责确定主节点：

```bash
init_or_get_primary_from_redis_sentinel
if check_current_pod_is_primary; then
  return
else
  echo "replicaof $primary $primary_port" >> $redis_real_conf
fi
```

当使用 Sentinel 时，脚本会向 Sentinel 查询当前主节点地址，然后与本地的 `replica-announce-ip/port` 比较，判断自己是否是主节点。

### 7.2 主节点判断逻辑

`check_current_pod_is_primary()` 支持多种匹配方式：

```bash
check_current_pod_is_primary() {
  # 1. 通过 Pod FQDN 前缀匹配
  current_pod_fqdn_prefix="$CURRENT_POD_NAME.$REDIS_COMPONENT_NAME"
  if contains "$primary" "$current_pod_fqdn_prefix"; then
    return 0
  fi

  # 2. 通过 advertised svc host/port 匹配
  if ! is_empty "$redis_announce_host_value" && ! is_empty "$redis_announce_port_value"; then
    if equals "$primary" "$redis_announce_host_value" && equals "$primary_port" "$redis_announce_port_value"; then
      return 0
    fi
  fi

  # 3. 通过 Pod IP 匹配
  if equals "$primary" "$CURRENT_POD_IP" && equals "$primary_port" "$service_port"; then
    return 0
  fi
  return 1
}
```

这说明 `replica-announce-ip/port` 不仅影响外部访问，也参与 Sentinel 模式下的角色判断。

---

## 8. 设计要点总结

1. **容器内端口固定**
   - Redis 进程始终监听 `6379`，不随外部 Service 类型变化。
   - 外部端口与内部监听端口的差异通过两方面配合解决：一是 Service 的 `targetPort` 映射，将外部 Service 端口转接到容器固定端口；二是 Redis 的 `replica-announce-ip` 和 `replica-announce-port` 配置项，向客户端和其他副本宣告外部可访问地址。

2. **外部访问地址完全由 Service 类型决定**
   - NodePort：外部地址 = Node IP + NodePort。
   - LoadBalancer：外部地址 = LB Ingress + 服务端口（硬编码 6379）。
   - HostNetwork：外部地址 = Node IP + 分配的主机端口。
   - 默认：使用 Pod FQDN + 6379。

3. **控制面与容器内脚本分层清晰**
   - 控制面负责：创建 Service、分配端口/LB IP、构建环境变量。
   - 容器内脚本负责：解析环境变量、按 Pod ordinal 匹配、生成 Redis 配置。

4. **per-pod Service 是 NodePort/LB 方案的前提**
   - 每个 Pod 需要独立的 Service 才能获得独立的外部端点。
   - 环境变量通过 `svcName:value,svcName:value,...` 的格式聚合所有 per-pod Service 信息。
   - 容器内脚本端通过 ordinal 匹配找到当前 Pod 对应的那一项。

5. **LoadBalancer 场景下 announce-port 硬编码为 6379**
   - 因为 LB Service 的 `spec.ports[].port` 就是外部访问端口。
   - 这一硬编码隐含假设 LB 端口始终为 6379。

6. **Sentinel 模式下 announce 配置参与主从判断**
   - Sentinel 返回的主节点地址会与本地 `replica-announce-ip/port` 比较。
   - 这要求 announce 配置必须准确反映外部可访问地址。

---

## 9. 参考源码位置

- `kubeblocks-addons/addons/redis/templates/cmpd-redis.yaml`
- `kubeblocks-addons/addons/redis/scripts/redis-start.sh`
- `kubeblocks/pkg/controller/component/vars.go`
- `kubeblocks/controllers/apps/component/transformer_component_service.go`
- `kubeblocks/pkg/constant/pattern.go`
