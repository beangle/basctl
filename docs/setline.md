# setline（本地代理）

`basctl setline` 把 `conf/server.xml` 的服务拓扑渲染成
[setline](https://github.com/beangle/setline) 的 JSON 配置：setline 在本地监听**一个入口地址**，
按 Host + 路径前缀把请求转发到各 server 的 http 端口，从而用一个地址访问全部 webapp。它只生成
配置，不启动 setline。

setline 的后端按约定固定为 `127.0.0.1:<port>`，因此这条路径面向「所有实例都跑在本机」的开发场景。

## 用法

```sh
basctl setline [server.xml] [--output=<file>] [--listen=<addr>]
```

| 参数 | 缺省 | 说明 |
|---|---|---|
| `server.xml` | `$BAS_HOME/conf/server.xml` | 拓扑来源 |
| `--output` | `$BAS_HOME/conf/setline.json` | 配置写出位置；`-` 表示写 stdout（取片段用） |
| `--listen` | `127.0.0.1:8080` | 入口地址：`8080` / `*:8080` / `127.0.0.1:8080` 都可以，与 setline 的 `listen` 一致 |

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
  其它服务不受影响。接口用法见 setline 的 `docs/runtime-routes-api.md`。

两种方式都不需要改动本命令：`basctl setline` 只写 `--output` 指定的文件（缺省
`conf/setline.json`），不会去读或改已有的全局配置——怎么合并由你决定。
