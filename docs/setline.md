# setline（本地代理）

[setline](https://github.com/beangle/setline) 是独立的机器级服务：它监听一个入口地址，按 Host +
路径前缀把请求转发到各 server 的 http 端口，从而用一个地址访问全部 webapp。

`basctl setline` 只做一件事：把**运行中实例**的路由推给已经在跑的 setline——推一次就结束（幂等，
只替换本 `BAS_HOME` 那一格）。配了 `<setline>` 时 `basctl start` / `stop` 会各自在动作之后对账
一次（`--no-setline` 跳过），所以日常根本不用手工敲它：**路由变化的时机就是实例的启停**。

**setline 的进程与它自己的配置都不归 basctl**：进程由 systemd / 容器入口 / 手工拉起来，`listen` /
`adminListen` / 调参写在 setline 自己那份配置里（basctl 不生成、不读取、不覆盖）；basctl 只需要
知道**管理口**在哪（`server.xml` 的 `<setline port>`，唯一来源、没有缺省），用来推路由、
知道**管理口**在哪（`server.xml` 的 `<setline port>`，唯一来源、没有缺省），用来推路由、
读路由表——写接口只认回环来的连接，所以 basctl 拨的固定是 `127.0.0.1:<port>`，配置里也就只有
端口。
推送失败时报「没人应答」，不会替你把它拉起来。设计见 [setline-config.md](setline-config.md)。

setline 的后端按约定固定为 `127.0.0.1:<port>`，因此这条路径面向「所有实例都跑在本机」的开发场景。

## 用法

```sh
basctl setline [server.xml]
```

| 参数 | 缺省 | 说明 |
|---|---|---|
| `server.xml` | `$BAS_HOME/conf/server.xml` | 只用来取 `hostname` 与 `port`，路由不来自它；没有 `<setline>` 就没端口可推，报错退出 |
| `--sync` | 关 | 显式写法，等同不带参数的这次推送（给脚本与肌肉记忆留的拼法） |

**只推一次，没有 `--watch`**：setline 自己就是常驻服务，"什么时候该改路由"由实例的启停说清
（`start` / `stop` 之后各对账一次），不需要第二个轮询进程再猜一遍。要从外部状态漂移（例如
`kill -9` 掉一个实例）里恢复，跑一次 `basctl setline`（`basctl status` 的 route 列会告诉你有
没有漂移）。

**输入永远是「现状」**（`servers/<name>/server.info`）：配置改了但实例没重启时路由不变，动态
端口也只有运行信息里才有。

setline 的 `routes` 以 Host 分组，分组键就是 `server.xml` 的 `<setline hostname>`（缺省
`*`，匹配任意 Host）——一台机器上共享同一个 setline 的多份 `BAS_HOME` 各写自己的
`hostname`，互不覆盖。访问地址则是 `http://<hostname>:<setline 的 listen 端口>/...`，那个端口在
setline 自己的配置里，basctl 不猜也不改：

```sh
$ basctl setline
4 routes synced to http://127.0.0.1:10080 (host=*)
```

## 启用、命名空间与管理口端口：`<setline>`

`<setline>` 出现即启用、不出现即禁用——配置本身就是开关。它有两项：`port` 必填，
`hostname` 可省（缺省 `*`）。不写 `<setline>` 时 basctl 完全不碰 setline，`start` /
`stop` / `status` 也不会因为"没有端口"报错。

```xml
<bas version="0.14.0">
  <!-- ... repositories / engines / hosts / farms / webapps ... -->
  <setline hostname="alice.localhost" port="10080"/>
</bas>
```

- `hostname`（缺省 `*`）：路由写进哪个命名空间，见上；
- `port`（**必填**，没有缺省）：setline 的**管理口**（`adminListen`）端口，basctl 拨
  `127.0.0.1:<port>` 推 `PUT /_setline/routes/all`、读 `GET /_setline/routes`。缺了或写法非法，
  解析 `server.xml` 时就报错。**只写端口，不写 host**：管理口的写接口只认回环来的连接（对端与
  Host 都是回环），写别的地址进去必然被拒——那是个看着能配、实际没有余地的旋钮。它也不是 setline
  对外接业务的 `listen`——那是 setline 自己配置里的端口，浏览器访问用的是它，basctl 既不读也不写。

健康检查、连接超时这类调参属于 setline 自己那份配置；basctl 不生成它，也不把它翻译进拓扑。

端口只有一个来源（解析也只有一处在做，见 `bas.endpoint.resolveSetlinePort`）：`server.xml`
的 `<setline port>`，元素出现时必填，没有命令行覆盖、没有缺省。配置里没有 `<setline>` 就是
这份 `BAS_HOME` 没启用 setline——没有命名空间、也没有管理口端口，`basctl setline` 报一句退出；
`start` / `stop` / `status` 也不碰 setline。所以"它到底拨哪儿"只有一处答案。

**写接口只在管理口上，且只认本机**（回环对端 + 回环 Host），管理口缺省绑回环——"只有本机能改流量
走向"因此是 TCP 层的事实，不靠凭据。**读接口**（路由表）本机一律放行，其它机器要写在 setline 的
`peerReaders` 里，否则回 `403`；setline 不持有任何凭据，`server.xml` 里也没有 token 可写（写的是
端口，不是秘密）。

## 运行期同步（推送）

**同步的输入是「现状」而不是 `server.xml`**：路由由 `servers/<name>/server.info` 算出（存活的
pid、实际端口、各 webapp 的对外 url），因此配置改了但实例没重启时路由不变，动态端口也能被覆盖。

推送只有一步：`PUT /_setline/routes/all?host=<hostname>` 整组替换**这个命名空间**的路由
（幂等，别的分组不受影响）。管理口没人监听就报错并退出，不改动任何东西——把 setline 拉起来是
systemd / 容器入口 / 你自己的事。

遇到**路由冲突**时打印原因并**保持现状**（现有路由继续服务，不动 setline），改好 `<url path>`
之后再推一次。它只写路由，不碰应用进程，也不写 `server.info`（唯一写者仍是 `start` / `stop`）。

配了 `<setline>` 时，`start` / `stop` 各自在动作之后跑一次对账；失败**只警告**，不改启停的退出码
——setline 挂了不该挡住应用启停，下一次启停（或手工 `basctl setline`）会把路由补齐。
`--no-setline` 可临时跳过这一次对账。

推送是瞬时的：拨一次管理口，推完就退出。路由由 setline 在收到推送后写回它自己的配置文件（只替换
`routes`），所以 setline 重启后路由不丢——只要它读的是同一份文件。

## 状态（`basctl status`）

配了 `<setline>` 时，`basctl status` 在实例列表之后另起一节：首行是命名空间、basctl 拨的管理口
地址与它通不通，随后是 route 列——拿「运行中实例该有的路由」（同推送的输入）和 setline 上的
实际路由对一次账：

```
---------------setline---------------
host=* port=10080 (up)
  /api  setline has 8081, want [8081, 8088]
  /tools  missing on setline (want 8090)
  /old  not in this BAS_HOME (setline has 9000); a `setline --sync` removes it
```

- `(up)`：管理口（`127.0.0.1:<port>`）有人应答——setline 是机器级服务，`status` 只报「通不通」，
  不猜坐的是谁；
  `(down)`：管理口没人监听，说明 setline 服务没在跑（这时不拨号，route 列也不再往下写）；
- `routes in sync (N)`：该有的路由条数，且与 setline 上的完全一致；
- `missing on setline` / `setline has ..., want ...`：`start` 之后没推上去（setline 刚起，或推送
  只警告过），或端口漂移后没对账（`stop` / `start` 之间漏了一次，手工 `basctl setline` 即修）；
- `not in this BAS_HOME`：实例已停但路由还留着（对账没跑到）；这类多出来的路由按路径排序输出，
  与"少的"一样都是对账没跟上的信号；
- `host=* (No setline admin port: ...)`：手工构造的容器（`Container` 是公开类型）缺
  端口时的兜底；正常路径上"有 `<setline>` 就有 `port`"由配置校验保证，写坏了在解析
  `server.xml` 时就报错。

route 列读的是 setline 的**读**接口（`GET /_setline/routes`）——只读、无副作用。读接口对回环
来源一律放行，所以这条路径开箱即用；只有把 `<setline port>` 拨到**另一台机器**上的 setline
时才可能被拒，那一行会写成
`routes: <addr> refuses reads from this host (setline allows localhost and its peerReaders list)`：
对方要么把本机地址写进它的 `peerReaders`，要么这次 `status` 只能读不到（basctl 不持有凭据，也不
会为一次 `status` 去配一个）。管理口通了但不是 setline（应答形状不对）、或连不上，也各用一行说清。

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

以上规则对推送与 `status` 的 route 列一致，数据来源都是 `server.info`（因此 `http="0"` 的实例
同样有路由，端口是分配出来的那个）；`start` 前的那次冲突预检读 `server.xml`，用的是同一套规则。

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

setline 侧：它自己那份配置给出对外接业务的 `listen`（例子里 `*:8080`，由拥有它的人写），
`basctl setline` 把下面这一格推到 `hostname` 命名空间下（`routes` 里别的分组不动）：

```json
{
  "*": {
    "/api/platform": 8081,
    "/portal": 8081
  }
}
```

之后 `http://<hostname>:8080/portal` 与 `http://<hostname>:8080/api/platform` 就分别落到
`127.0.0.1:8081` 上。

## 边界与定位

- **只覆盖 bas 管辖的服务**：路由全部来自 `server.xml` 的 farm / server / webapp，不含 basctl
  之外的服务。
- **代理是全局的**：一台机器上通常只有一份 setline，它同时服务 bas 与别的系统。`basctl setline`
  只推 bas 那一格（`<setline hostname>` 命名空间），别的分组不动。
- 生产入口（haproxy / nginx / ...）与本地 setline 代理是两件事，`server.xml` 不描述前者；
  basctl 只把路由推给 setline（管理口端口由 `<setline port>` 给出），不会替 haproxy / nginx
  生成配置。
- Linux only：setline 基于 epoll，且后端固定为回环地址，无法代理其它主机上的 server。
- 只做 HTTP/1.x 转发，不终止 TLS，也不做路径改写（前缀原样透传）。

## 别人怎么读这些路由

basctl 不产出文件，路由只有两个去向：推给 setline，以及被 setline 写回它自己的配置文件（`routes`
那一节）。要拿 bas 的拓扑去做别的事（生产入口的 haproxy / nginx 配置、监控），读 setline 的
`GET /_setline/routes`：本机放行，跨机需要在被读端的 `peerReaders` 里写上读方地址；接口形状见
setline 的 `docs/runtime-routes-api.md`。basctl 不导出平行的中间格式。

## 后续演进

生产侧（haproxy / nginx 那台机器上）的拓扑 agent 记在 [roadmap.md](roadmap.md) 的 R3；
产出侧已定：交付物就是 `server.xml`，消费方复用 bas 的配置模型，需要运行态则读 setline 的
`GET /_setline/routes`，basctl 不导出平行的中间格式。
