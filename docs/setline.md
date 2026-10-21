# setline（本地代理与配置）

[setline](https://github.com/beangle/setline) 是独立的机器级 HTTP 代理：从一个入口端口接收请求，
按 Host + 路径前缀转发到本机各 server 的 HTTP 端口。

basctl 只负责把**运行中实例**的路由推给 setline。setline 的进程、`listen`、`adminListen` 和
健康检查等参数都由 setline 自己的配置管理；basctl 不启动、不停止它，也不生成或修改它的配置。

## 1. 配置 setline

先准备 setline 自己的配置文件，例如 `/etc/setline/setline.json`：

```json
{
  "listen": "*:8080",
  "adminListen": "127.0.0.1:10080",
  "routes": {}
}
```

| 配置项 | 作用 |
|---|---|
| `listen` | 对外接业务的地址，例如 `*:8080` |
| `adminListen` | basctl 推路由的管理口，建议保持 `127.0.0.1:10080` |
| `routes` | 运行期路由；由 setline 自己维护，初始为空即可 |

启动 setline：

```sh
setline -f /etc/setline/setline.json
```

setline 写回配置时只替换 `routes`，不会改 `listen` / `adminListen`。运行期路由会持久化，
setline 重启后仍然保留。

## 2. 在 server.xml 中启用

在 `conf/server.xml` 中加入：

```xml
<setline hostname="alice.localhost" port="10080"/>
```

| 属性 | 必填 | 说明 |
|---|---|---|
| `hostname` | 否 | 路由命名空间，缺省为 `*`（匹配任意 Host） |
| `port` | 是 | setline 的 `adminListen` 端口，不是对外的 `listen` 端口 |

`port` 只写端口号，basctl 固定连接 `127.0.0.1:<port>`。没有 `<setline>` 时，basctl 完全不处理
setline，也不会因为缺端口而报错。

## 3. 启停与路由同步

日常不需要手工推路由：

```sh
basctl start all
basctl stop all
```

配置了 `<setline>` 时，`start` / `stop` 会在动作完成后自动对账一次，把当前活着的实例和实际端口
同步给 setline。对账失败只打印警告，不影响实例启停。`--no-setline` 可跳过这次对账。

需要手工修正外部状态漂移时：

```sh
basctl setline
basctl setline --sync   # 同一次动作的显式写法
```

成功时输出类似：

```text
4 routes synced to http://127.0.0.1:10080 (host=*)
```

同步的输入是 `servers/<name>/server.info`，也就是当前运行状态；配置改了但实例没重启时，路由
不会变化。动态端口也会按实际分配到的端口同步。

setline 必须已经在运行；管理口没人监听时 basctl 只会报错退出，不会代你启动 setline。

## 4. 查看状态

```sh
basctl status
```

配置了 `<setline>` 时，实例列表后会多出一节：

```text
---------------setline---------------
host=* port=10080 (up)
  /api  setline has 8081, want [8081, 8088]
  /tools  missing on setline (want 8090)
  /old  not in this BAS_HOME (setline has 9000)
```

- `(up)`：管理口可达；`(down)`：setline 没有运行或端口不对。
- `routes in sync`：setline 上的路由与当前实例一致。
- `missing on setline`：实例有路由，但 setline 上还没有，执行一次 `basctl setline` 通常即可修复。
- `setline has ..., want ...`：端口不一致。
- `not in this BAS_HOME`：setline 上残留了本配置已不使用的路由。

`status` 只读，不启动、不停止、也不修改 setline。

## 5. 对外访问与路由规则

配置 `<setline hostname="alice.localhost" port="10080"/>` 后，访问地址是：

```text
http://alice.localhost:<setline 的 listen 端口>/<路径>
```

路由来源：

- 路径取 webapp 的 `<url path="..."/>`；没有声明 `<url>` 时取 context path。
- 端口取该 webapp 的 `run-at` 目标 server 的 `http` 端口。
- 同一个路径部署在多个 server 上时合并成端口列表。
- 没有 `run-at`、或 server 没有 HTTP 端口的 webapp 不生成路由。
- 同一个路径被不同端口集合的 webapp 同时占用时，basctl 报 `Route conflict` 并保持现有路由不变。

## 6. 多份 BAS_HOME 共享一个 setline

每份 `BAS_HOME` 使用同一个 `port`，但 `hostname` 必须各不相同：

```xml
<!-- alice -->
<setline hostname="alice.localhost" port="10080"/>

<!-- bob -->
<setline hostname="bob.localhost" port="10080"/>
```

各自执行 `basctl start all` 只会更新自己的命名空间，互不覆盖。缺省 `*` 只适合一份 `BAS_HOME`
接入 setline 的机器；多份共享时必须显式写域名。

## 7. 安全与限制

- `basctl stop` 不会停止 setline；setline 的进程由启动它的系统或服务自行管理。
- 管理口只接受本机回环连接，basctl 推路由不需要 token。
- 别的机器要读取这台 setline 的路由表，需要在 setline 配置的 `peerReaders` 中登记其地址。
- setline 只代理本机 `127.0.0.1:<port>` 后端，面向 Linux 和 HTTP/1.x。
- 不终止 TLS、不重写路径，也不是生产级负载均衡；生产入口仍由 haproxy / nginx 等负责。
- basctl 只推路由，不管理 setline 进程，也不生成其配置文件。
