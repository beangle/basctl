# Proxy endpoints

本文定义 `server.xml` 中代理点（endpoint）的配置模型，以及它和 `runAt`、setline group 的关系。

## 1. server.xml

```xml
<proxies>
  <proxy name="edge-a"
         ip="10.0.0.20,10.0.0.21"
         domain="www.example.com"/>

  <proxy name="edge-ip"
         ip="10.0.0.30,10.0.0.31"/>
</proxies>

<webapps>
  <webapp uri="gav://..."
          run-at="farm.server"
          endpoints="edge-a,edge-ip">
    <url path="/a/b/c"/>
  </webapp>
</webapps>
```

规则：

- `name` 必填，全局唯一。
- `domain` 可选；非空时全局唯一。
- `ip` 必填，逗号分隔；是代理机的**内网地址**，不是域名对应的公网地址。
- 同一个 endpoint 内 IP 去重。
- 多个无域名 endpoint 的 IP 集合必须两两不相交。
- 有域名 endpoint 之间可以共享 IP；有域名和无域名之间也可以共享 IP。
- `cert`、`force-https` 不写入 `server.xml`；它们属于 bashub 的 endpoint 配置，由 setline agent pull。
- `endpoints` 引用 proxy 的 `name`；省略或为空表示不做负载代理。
- 多个无域名 endpoint 使用同一个 IP 会使 group 冲突，因此在解析阶段拒绝。

## 2. 多个 IP 的语义

```text
一个 endpoint = 一个逻辑代理点
多个 IP      = 同一域名分配到多台代理机
```

例如：

```text
edge-a:
  domain = www.example.com
  ip = 10.0.0.20, 10.0.0.21
```

表示 `www.example.com` 有两台代理机，公网 DNS 另行指向真实公网地址。

## 3. 每台机器一个 setline agent

每台代理机运行一个 setline agent。agent 配置只有：

```text
project
当前机器内网 IP
```

定位方式：

```text
project + 当前 IP
  → bashub 查询所有包含该 IP 的 endpoint
  → 逐个渲染代理和路由
```

不使用 profile。setline 配置里的旧 `profile` 命名后续改成 `project`；该改动优先级较低。

同一个内网 IP 可以出现在多个 endpoint 中，不做唯一限制。

## 4. setline group

### 有 domain

```text
group = domain
```

一个 endpoint 的多台代理机共享同一个 group。

### 无 domain

```text
group = 当前代理机 IP
```

例如：

```text
edge-ip ip = 10.0.0.30, 10.0.0.31
  10.0.0.30 → group 10.0.0.30
  10.0.0.31 → group 10.0.0.31
```

多个无域名 endpoint 的 IP 集合必须两两不相交，避免同一个 IP 产生多个无域名 group。

## 5. 路由校验

主键：

```text
(machine, group, path)
```

- `machine`：`server.host.ip`
- `group`：domain，或本机 IP
- `path`：`<url path>`，未声明时回退 context

规则：

| 场景 | 结果 |
|---|---|
| 同机器、同 group、同 path 重复 | 冲突 |
| 不同机器、同 group、同 path | 允许，端口合并 |
| 同机器、不同 group、同 path | 允许 |
| webapp 多个 endpoint、不同 group | 允许多组 |
| webapp 多个 endpoint、相同 group | 配置重复，报错 |
| 无 endpoint | 使用 `setline-hostname` / `*` |

## 6. 证书和 force-https

全部在 bashub 的 endpoint 配置中：

- `forceHttps`
- `certificate`
- `privateKey`
- 端口与 SSL 参数

证书可以为空；`forceHttps=true` 且证书为空时允许启动，由 certbot 等外部工具更新。

setline agent pull 返回当前 IP 命中的所有 endpoint，每个 endpoint 独立携带证书和 force-https。

## 7. 兼容

- `server.xml` 没有 `<proxies>` 时保持旧行为。
- webapp 没有 `endpoints` 时使用默认 group。
- 旧 proxy-settings 可由 bashub 迁移成一个 default endpoint，旧 webapp 保持原有代理行为。

## 8. 当前实现状态

已在 basctl 落地的第一阶段：

- `<proxies>` / `<proxy>` 解析
- `Webapp.endpoints`
- endpoint 名称、域名、无域名 IP 互斥校验
- `setlinePlans(conf)`：按 group 生成路由
- `(machine, group, path)` 冲突检测
- `server.info` 记录 webapp groups
- `runningGroupPlans` / 多 group 路由推送

尚未实现：

- bashub endpoint 表、API、UI
- server.xml 的 bashub 生成
- 按 endpoint 渲染 nginx/haproxy
- setline agent 按 project + IP 查询 endpoint
- endpoint 证书 pull
- status 的完整多 group 对账

## 9. 实施顺序

1. basctl 配置模型、XSD、解析和校验
2. setline group plan 与 `(machine, group, path)` 冲突
3. server.info / setline 多 group 推送与对账
4. bashub endpoint 表、API、UI、server.xml 生成
5. setline agent 的 project + IP 查询与证书 pull（优先级较低）
