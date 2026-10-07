# manifest：把拓扑导出成机器可读的 JSON

`basctl manifest [server.xml] [--output=<file>]` 把 `server.xml` 的**声明态拓扑**导成一份 JSON，
交给别的程序消费——不是给人看的，是给「边缘机的 setline agent」按它渲染 haproxy / nginx 用的
（setline-roadmap 的 R6）。缺省写 `$BAS_HOME/conf/manifest.json`，`--output=-` 写到 stdout。

```sh
basctl manifest                       # 写 conf/manifest.json
basctl manifest --output=- | jq .     # 取片段 / 接管道
```

## 为什么不是直接用 `conf/setline.json`

`basctl setline` 渲染的 `conf/setline.json` 是**本机 setline 进程的配置**：只有 `listen` 和一个
`hostname -> path -> port` 的路由表。它够用来在本机拉起一个代理，但不够让一台**别的机器**渲染
haproxy / nginx——那边还需要知道每个实例跑在哪个引擎上、webapp 的对外路径是怎么来的、要不要转发
WebSocket。manifest 就是这份"除了路由还要什么"的清单。

```json
{
  "version": 1,
  "generator": "basctl 0.0.1",
  "source": "/opt/bas/conf/server.xml",
  "bas": "0.14.0",
  "setline": { "enabled": true, "hostname": "localhost", "endpoint": "127.0.0.1:8080" },
  "servers": [
    {
      "name": "platform.server1",
      "farm": "platform",
      "engine": "tomcat-server-11.0.26",
      "type": "tomcat-server",
      "engineVersion": "11.0.26",
      "http": 8081,
      "connectionTimeout": 60000,
      "websocket": true,
      "jsp": false,
      "webapps": [
        {
          "contextPath": "/api/platform",
          "urls": [],
          "paths": ["/api/platform"],
          "uri": "gav://org.beangle.ems:beangle-ems-ws:4.17.2"
        }
      ]
    }
  ],
  "routes": { "localhost": { "/api/platform": 8081 } }
}
```

| 字段 | 含义 |
|---|---|
| `version` | manifest 的 schema 版本（`bas.manifest.manifestVersion`），字段不兼容变更时 +1 |
| `generator` / `source` / `bas` | 谁生成的、拿哪份 `server.xml`、`<bas version>` 是多少 |
| `setline.enabled` | 这份配置有没有 `<setline>`（即 basctl 会不会维护它的路由） |
| `setline.hostname` | 路由命名空间：`<setline hostname>`，缺省 `localhost`，`*` 表示任意 Host |
| `setline.endpoint` | 本 `BAS_HOME` 往外拨的入口地址；没写就没有这个字段（没有缺省值这件事也一并传递出去） |
| `servers[].engine` | `<type>-<版本>`，与 `--engine=` / `basctl run` 同一套写法 |
| `servers[].http` | `server.xml` 里声明的端口；`http="0"`（动态端口）原样是 `0` |
| `servers[].webapps[].urls` | `<webapp>` 下**声明**的 `<url path>`（没写就是空数组） |
| `servers[].webapps[].paths` | **生效**的对外路径：`urls` 优先，否则退回 `contextPath`（`Webapp.routePaths`） |
| `routes` | 与 setline 配置同形状的 `hostname -> path -> port\|[ports]`，想直接喂给 setline 就取这一段 |

`urls` 与 `paths` 都给出来是故意的：消费方不必再实现一遍"声明优先、否则退回 context path"的
回退规则，也就不会出现两边规则演进而输出不一致的漂移。

## 它是声明态，不是现状

端口取的是 `server.xml` 里写的值。声明了 `<server http="0">`（动态端口）时 manifest 里就是 `0`——
真实端口只有运行中的实例知道，那份"现状"在 `$BAS_HOME/servers/<name>/server.info` 里，由
`basctl status` / `basctl setline --sync|--watch` 消费（见 [server-info.md](server-info.md)）。
manifest 面向的 R6 是**生产侧**通道：那边端口是定的，要把拓扑发到别的机器上去；本机这一条动态
端口的链路（R0-R3）与它并行，互不依赖。

后端地址仍假设在回环，与 setline 一致：manifest 说的是"这些 server 跑在本机"。跨机部署由边缘机
渲染时替换后端地址——这正是它和 bashub 的 `haproxy.ftl` / nginx 模板对齐的位置。

## 冲突

同一路径被**端口集合不同**的 webapp 声明时无从判定归属（与 `basctl setline` 同一套判定，见
[setline.md](setline.md)），`manifest` 会照 `setline` 的做法报错退出，而不是导出一份消费方没
法用的拓扑；端口集合相同（同一个 webapp 的多个实例）仍然是合并成端口列表。
