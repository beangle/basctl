# setline（本地代理）

`basctl setline` 把 `conf/server.xml` 的服务拓扑渲染成
[setline](https://github.com/beangle/setline) 的 JSON 配置：setline 在本地监听**一个入口地址**，
按 Host + 路径前缀把请求转发到各 server 的 http 端口，从而用一个地址访问全部 webapp。

默认只渲染配置；`--sync` 把**运行中实例**的路由推给正在跑的 setline，`--watch` 常驻轮询对账。
配了 `<setline>` 时 `basctl start` / `stop` 会各自自动对账一次（`--no-setline` 跳过）。

**setline 的进程不归 basctl**：它由 systemd / 容器入口 / 手工拉起来，basctl 只认入口地址
（`--endpoint` > `<setline endpoint>`，没有缺省）并往它的写接口推路由——推送失败时报「入口没人
应答」，不会替你把它拉起来。设计见 [setline-config.md](setline-config.md)。

setline 的后端按约定固定为 `127.0.0.1:<port>`，因此这条路径面向「所有实例都跑在本机」的开发场景。

## 用法

```sh
basctl setline [server.xml] [--output=<file>] [--endpoint=<addr>]
basctl setline [server.xml] [--endpoint=<addr>] --sync
basctl setline [server.xml] [--endpoint=<addr>] --watch [--interval=<sec>]
```

| 参数 | 缺省 | 说明 |
|---|---|---|
| `server.xml` | `$BAS_HOME/conf/server.xml` | 拓扑来源 |
| `--output` | `$BAS_HOME/conf/setline.json` | 配置写出位置；`-` 表示写 stdout（取片段用） |
| `--endpoint` | 无（其次用 `<setline endpoint>`） | 入口地址：`8080` / `*:8080` / `127.0.0.1:8080` 都可以，与 setline 的 `listen` 同构（但 `*` 拨的时候会落到回环）；两处都没写就报错 |
| `--sync` | 关 | 把**运行中实例**（`servers/<name>/server.info`）的整组路由推给已在跑的 setline（幂等） |
| `--watch` | 关 | 常驻轮询，把运行中实例的路由持续推给 setline，直到 Ctrl-C；与 `--output` 互斥 |
| `--interval` | `5` | 只配 `--watch`：轮询间隔秒数（正整数） |

渲染与同步的**输入不同**：不带 `--sync` / `--watch` 时读 `server.xml` 的静态拓扑（用于取片段、
并入全局代理）；`--sync` / `--watch` 读运行信息，配置改了但实例没重启时路由不变，动态端口也只有
运行信息里才有。

setline 的 `routes` 以 Host 分组，分组键就是 `server.xml` 的 `<setline hostname>`（缺省
`localhost`，写 `*` 表示任意 Host）。访问地址因此是 `http://<hostname>:<入口端口>/...`：
一台机器上共享同一个 setline 的多份 `BAS_HOME` 各写自己的 `hostname`，互不覆盖。

生成后把结果位置、路由条数与入口地址打出来，直接照抄最后一行即可启动：

```sh
$ basctl setline
write /opt/bas/conf/setline.json
4 routes, entry http://127.0.0.1:8080, host=localhost
run: setline -f /opt/bas/conf/setline.json
```

已经有全局代理时，用 `--output=-` 取片段并入，见 [并入全局代理](#并入全局代理)。

## 启用、命名空间与入口地址：`<setline>`

`<setline>` 出现即启用、不出现即禁用——配置本身就是开关。它有两项：`endpoint` 必填，
`hostname` 可省（缺省 `localhost`）。不写 `<setline>` 时 basctl 完全不碰 setline，`start` /
`stop` / `status` 也不会因为"没有地址"报错。

```xml
<bas version="0.14.0">
  <!-- ... repositories / engines / hosts / farms / webapps ... -->
  <setline hostname="alice.localhost" endpoint="127.0.0.1:8080"/>
</bas>
```

- `hostname`（缺省 `localhost`）：路由写进哪个命名空间，见上；
- `endpoint`（**必填**，没有缺省）：本 `BAS_HOME` **往外拨**哪扇门。缺了或写法非法，解析
  `server.xml` 时就报错。

token、健康检查、连接超时这些要么属于 setline 自己的配置文件（`conf/setline.json`，归 setline
进程），要么是代理本身的调参，都不进拓扑。

取用顺序（只有一处在解析，见 `bas.endpoint.resolveSetlineEndpoint`）：`--endpoint` >
`<setline endpoint>`（元素出现时必填）。`--endpoint` 留给"这份配置没启用 setline、只想渲染/对账
一次"和临时覆盖：都没有地址可拨时才报错，没有缺省，也就没有"它到底拨哪儿"的第二种解释。

setline 的 `adminToken` 只管**读**的**非本机**来源（路由表与状态页），留给将来同网段的服务进程
读取用——例如把路由渲染成 haproxy / nginx 配置的同步程序。**本机来源（读写同一条门）不需要任何
凭据**，所以 `server.xml` 里不放 token：`--sync` / `--watch` 写路由、`status` 的 route 列读路由，
都是用同一个 localhost 入口，装上就能用。

## 运行期同步（`--sync` / `--watch`）

**同步的输入是「现状」而不是 `server.xml`**：路由由 `servers/<name>/server.info` 算出（存活的
pid、实际端口、各 webapp 的对外 url），因此配置改了但实例没重启时路由不变，动态端口也能被覆盖。

`--sync` 只有一步：`PUT /__setline/routes/all?host=<hostname>` 整组替换**这个命名空间**的路由
（幂等，别的分组不受影响）。入口没人监听就报错并退出，不改动任何东西——把 setline 拉起来是
systemd / 容器入口 / 你自己的事。

`--watch` 把这一步放进轮询循环：每 `--interval`（缺省 5 秒）读一次运行信息，路由表有变化才
推送（渲染结果相同就跳过），闲时因此不产生流量。遇到**路由冲突**时打印一次原因并**保持现状**
（现有路由继续服务，不动 setline），改好 `<url path>` 后下一个周期自动推。Ctrl-C 退出；它只写
路由，不碰应用进程，也不写 `server.info`（唯一写者仍是 `start` / `stop`）。

配了 `<setline>` 时，`start` / `stop` 各自在动作之后跑一次对账；失败**只警告**，不改启停的退出码
——setline 挂了不该挡住应用启停，下一个 `--sync` / `--watch` 会补上。`--no-setline` 可临时跳过
这一次对账。

`--sync` 每次调用都是瞬时的，`--watch` 才会常驻（交给 systemd）。路由由 setline 在收到推送后
写回它自己的配置文件（只替换 `routes`），所以 setline 重启后路由不丢——只要它读的是同一份文件。

## 状态（`basctl status`）

配了 `<setline>` 时，`basctl status` 在实例列表之后另起一节：首行是命名空间、入口地址与入口
状态，随后是 route 列——拿「运行中实例该有的路由」（同 `--sync` 的输入）和 setline 上的实际
路由对一次账：

```
---------------setline---------------
host=localhost endpoint=127.0.0.1:8080 (up)
  /api  setline has 8081, want [8081, 8088]
  /tools  missing on setline (want 8090)
  /old  not in this BAS_HOME (setline has 9000); a `setline --sync` removes it
```

- `(up)`：入口有人应答——setline 是机器级服务，`status` 只报「通不通」，不猜坐的是谁；
  `(down)`：入口没人监听，说明 setline 服务没在跑（这时不拨号，route 列也不再往下写）；
- `routes in sync (N)`：该有的路由条数，且与 setline 上的完全一致；
- `missing on setline` / `setline has ..., want ...`：`start` 之后没推上去（setline 刚起，或推送
  只警告过），或端口漂移后没对账（`--watch` 没在跑）；
- `not in this BAS_HOME`：实例已停但路由还留着（对账没跑到）；这类多出来的路由按路径排序输出，
  与"少的"一样都是对账没跟上的信号；
- `host=localhost (No setline entry address: ...)`：手工构造的容器缺地址时的兜底（正常路径上
  "有 `<setline>` 就有 `endpoint`"由配置校验保证，写坏了在解析 `server.xml` 时就报错）。

route 列读的是 setline 的**读**接口（`GET /__setline/routes`）——只读、无副作用。setline 对本机
来源免凭据，所以这条路径开箱即用、`server.xml` 里不需要 token；只有把 `<setline endpoint>` 指向
**另一台机器**上的 setline 时才可能撞上凭据墙，那一行会写成
`routes: <addr> wants adminToken for non-local reads (basctl holds no token)`：basctl 不存凭据，
宁可如实报也不猜。入口通了但不是 setline（应答形状不对）、或连不上，也各用一行说清。

`status` 只读：它不启动、不停止、也不修改任何东西（route 列只是一次 GET）。

## 停止与清空路由

`basctl stop` 停的是应用实例，**不停** setline：入口是机器级的，可能还在服务别的系统或别的
`BAS_HOME`。谁拉起的谁负责停——systemd 用 `systemctl stop`，容器入口收 SIGTERM 自己收尾。
想让本 `BAS_HOME` 的路由消失，用 `basctl stop all` 之后的那次对账（把命名空间置空），不用动进程。

## 路由生成规则

- 路径前缀取 `<webapp>` 声明的 `<url path="..."/>`（可多条）；一条都没声明时退回 context path
  （`path="/"` 或省略为 `/`）。也就是说 `path` 描述的是部署上下文，`<url>` 才是对外暴露的路径。
- 端口取该 webapp 的 `run-at` 目标 server 的 `http`。
- 同一路径落在多个 server 上时合并成端口列表，由 setline 在健康实例间选择（自带 TCP 健康检查）。
- 没有 `run-at`、或 server 未声明 `http`（端口 0）的 webapp 跳过。
- 同一路径被**端口集合不同**的多个 webapp 认领时无法判定归属，命令报冲突并退出，不写配置；
  端点集合相同时合并，不算冲突（同一 webapp 的多实例部署）。
- 路由按路径排序，输出稳定，便于纳入版本管理或 diff。

以上规则对渲染与 `--sync` / `--watch` 一致，区别只在数据来源：渲染读 `server.xml`，`--sync` /
`--watch` 读 `server.info`（因此 `http="0"` 的实例在运行期同样有路由，端口是分配出来的那个）。

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
  本地入口用 `<setline endpoint>`（或一次性的 `--endpoint`）指定。
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

生产侧（haproxy / nginx 那台机器上）要不要一个拉拓扑、渲染反代配置的 agent，以及它的通道
（registry、拉取频率与鉴权、`reload` 还是 `restart`）尚未定；产出侧已定：交付物就是
`server.xml`，消费方复用 bas 的配置模型，需要运行态则读本文件的 `GET /__setline/routes`，
basctl 不导出平行的中间格式。边界与未定项见 [features.md](features.md)。
