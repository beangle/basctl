# setline（本地代理）

`basctl setline` 把 `conf/server.xml` 的服务拓扑渲染成
[setline](https://github.com/beangle/setline) 的 JSON 配置：setline 在本地监听**一个入口地址**，
按 Host + 路径前缀把请求转发到各 server 的 http 端口，从而用一个地址访问全部 webapp。

默认只渲染配置、不碰进程；`--sync` 会把路由推给正在跑的 setline（入口空着就地拉起来），
`--stop` 停掉 basctl 自己起的那个。

setline 的后端按约定固定为 `127.0.0.1:<port>`，因此这条路径面向「所有实例都跑在本机」的开发场景。

## 用法

```sh
basctl setline [server.xml] [--output=<file>] [--listen=<addr>] [--sync]
basctl setline --stop [--force]
```

| 参数 | 缺省 | 说明 |
|---|---|---|
| `server.xml` | `$BAS_HOME/conf/server.xml` | 拓扑来源 |
| `--output` | `$BAS_HOME/conf/setline.json` | 配置写出位置；`-` 表示写 stdout（取片段用） |
| `--listen` | `<setline listen>`，都没有时 `127.0.0.1:8080` | 入口地址：`8080` / `*:8080` / `127.0.0.1:8080` 都可以，与 setline 的 `listen` 一致 |
| `--sync` | 关 | 确保入口可用，再把整组路由推给 setline（幂等） |
| `--stop` | 关 | 停掉 basctl 就地启动的 setline（按 `$BAS_HOME/run/setline.pid`） |
| `--force` | 关 | 只配 `--stop`：SIGTERM 后仍不退时用 SIGKILL |

setline 的 `routes` 以 Host 分组，而 `server.xml` 里没有 hostname，basctl 无从得知分组依据，
因此全部路由固定写进兜底命名空间 `*`——整个拓扑就是**一个分组**，按路径匹配任意 Host。要把它
归到某个域名下，合并时改这一个键即可（或用运行期接口按 host 写入）。

生成后把结果位置、路由条数与入口地址打出来，直接照抄最后一行即可启动：

```sh
$ basctl setline
write /opt/bas/conf/setline.json
4 routes, entry http://127.0.0.1:8080
run: setline -f /opt/bas/conf/setline.json
```

已经有全局代理时，用 `--output=-` 取片段并入，见 [并入全局代理](#并入全局代理)。

## 入口与启用：`<setline>`

入口写在 `server.xml` 里，出现即启用、不出现即禁用——配置本身就是开关，不再另设环境变量：

```xml
<bas version="0.14.0">
  <!-- ... repositories / engines / hosts / farms / webapps ... -->
  <setline listen="127.0.0.1:8080"/>
</bas>
```

元素只有 `listen` 一项：token、健康检查、连接超时这些要么属于 setline 自己的配置文件
（`conf/setline.json`，归 setline 进程），要么是代理本身的调参，都不进拓扑。
缺省 `--listen > <setline listen> > 127.0.0.1:8080`。

setline 的 `adminToken` 只管**读**（路由表与状态页），留给将来同网段的服务进程读取用——例如把
路由渲染成 haproxy / nginx 配置的同步程序。basctl 只走**写**接口（只认本机、不需要 token），
所以 `server.xml` 里不放凭据。

## 运行期同步（`--sync`）

`--sync` 按「先落文件、再要入口、最后推路由」三步走：

1. 要一份 `conf/setline.json`：**不存在才写骨架**（`listen` + 空 `routes`），已有的一律不改
   ——那是 setline 自己的配置（`adminToken`、健康检查等都在里面），basctl 只读不写；
2. 要入口：入口空闲就地启动 setline；已在跑（systemd、手工或别的 `BAS_HOME` 起的）直接复用
   ——判断办法就是试着写一次路由，写接口只认本机、不需要 token，能写进去就是我们的 setline；
   被别的进程占用则报错退出，不改动任何东西；
3. `PUT /__setline/routes/all?host=*` 整组替换兜底命名空间的路由（幂等，别的 host 分组不受影响）。

就地启动的 setline：`nohup setline -f <conf/setline.json>`，pid 记 `$BAS_HOME/run/setline.pid`，
日志写 `$BAS_HOME/logs/setline.out`。可执行文件按 `PATH` 上的 `setline` 查找，可用环境变量
`bas_setline` 覆盖（与 `bas_jstart` 同一约定）。每次调用都是瞬时的——basctl **没有**常驻进程。
路由由 setline 在收到推送后写回该文件（只替换 `routes`），所以重启不丢；文件里的 `listen`
与 `<setline listen>` 不一致时只提示一句，实际监听以文件为准。

## 停止（`--stop`）

`basctl stop` 停的是应用实例，**不停** setline：入口是机器级的，可能还在服务别的系统。
要停就地启动的那一个用 `basctl setline --stop`；它会先 SIGTERM 并等 10 秒，仍不退时提示
`--force`，加了才 SIGKILL。pid 文件不存在或进程已不在时不算错——顺手清掉陈旧的 pid 文件。

## 路由生成规则

- 路径前缀取 `<webapp>` 声明的 `<url path="..."/>`（可多条）；一条都没声明时退回 context path
  （`path="/"` 或省略为 `/`）。也就是说 `path` 描述的是部署上下文，`<url>` 才是对外暴露的路径。
- 端口取该 webapp 的 `run-at` 目标 server 的 `http`。
- 同一路径落在多个 server 上时合并成端口列表，由 setline 在健康实例间选择（自带 TCP 健康检查）。
- 没有 `run-at`、或 server 未声明 `http`（端口 0）的 webapp 跳过。
- 同一路径被**端口集合不同**的多个 webapp 认领时无法判定归属，命令报冲突并退出，不写配置；
  端点集合相同时合并，不算冲突（同一 webapp 的多实例部署）。
- 路由按路径排序，输出稳定，便于纳入版本管理或 diff。

### 上下文为 `/` 的 webapp

有的 webapp 上下文是 `/`，内部却按 `/context1`、`/context2` 分组；若这些 URL 没有公共前缀，
就只能声明上下文为 `/`。两个这样的 webapp 无法靠路径区分端口——`contextPath` 都是 `/`——此时
必须逐条列出各自的对外路径：

```xml
<webapp uri="gav://org.beangle.otk:beangle-otk-ws:war:0.0.30" run-at="one" path="/">
  <url path="/context1"/>
  <url path="/context2"/>
</webapp>
<webapp uri="gav://org.beangle.ems:beangle-ems-ws:4.17.2" run-at="two" path="/">
  <url path="/context3"/>
  <url path="/context4"/>
</webapp>
```

声明了 `<url>` 就不再认领 context path（上例的 `/` 不会生成路由）。未声明时两个 webapp 都占 `/`，
`basctl setline` 会报 `Route conflict on /` 并列出双方，而不是随机挑一个端口。

## 示例

```xml
<farms>
  <farm name="platform" engine="tomcat">
    <server name="server1" http="8081"/>
  </farm>
</farms>
<webapps>
  <webapp uri="gav://org.beangle.ems:beangle-ems-portal:4.17.2" run-at="platform" path="/portal"/>
  <webapp uri="gav://org.beangle.ems:beangle-ems-ws:4.17.2" run-at="platform" path="/api/platform"/>
</webapps>
```

```json
{
  "listen": "127.0.0.1:8080",
  "routes": {
    "*": {
      "/api/platform": 8081,
      "/portal": 8081
    }
  }
}
```

之后 `http://127.0.0.1:8080/portal` 与 `http://127.0.0.1:8080/api/platform` 就分别落到
`127.0.0.1:8081` 上。

## 边界与定位

- **只覆盖 bas 管辖的服务**：路由全部来自 `server.xml` 的 farm / server / webapp，不含 basctl
  之外的服务。
- **代理是全局的**：一台机器上通常只有一份 setline，它同时服务 bas 与别的系统。`basctl setline`
  只产出 bas 那部分路由，**不要拿它整体覆盖**全局配置——把它当片段并入（见下）。
- 生产入口（haproxy / nginx / ...）与本地 setline 代理是两件事，`server.xml` 不描述前者；
  本地入口用 `--listen` 指定。
- Linux only：setline 基于 epoll，且后端固定为回环地址，无法代理其它主机上的 server。
- 只做 HTTP/1.x 转发，不终止 TLS，也不做路径改写（前缀原样透传）。

## 并入全局代理

`basctl setline` 的输出是完整 JSON，但只含 bas 的路由（`--output=-` 时直接写 stdout）。接入
全局代理有两种方式：

- 文件方式：把输出存成片段，按 host 合并进全局配置的 `routes` 对象（键是路径前缀，同键合并
  端口列表）；
- 运行期方式：调 setline 的 `__setline/routes/all` 管理接口，只替换 bas 占用的 host 或前缀，
  其它服务不受影响（`--sync` 走的就是这条路）。写接口只接受本机来源且不需要 token，因此这条
  路只能在本机走；**读**路由表才有 token（`X-Setline-Token` / 状态页 Basic Auth），同网段的
  服务进程可以用它取拓扑。接口用法见 setline 的 `docs/runtime-routes-api.md`。

两种方式都不需要改动本命令：`basctl setline` 只写 `--output` 指定的文件（缺省
`conf/setline.json`），不会去读或改已有的全局配置——怎么合并由你决定。

## 后续演进

动态端口与自动注册、运行期对账、basctl 容器化单出口、host 分组等设想都在
[setline-roadmap.md](setline-roadmap.md)，本文件只描述已经存在的行为。
