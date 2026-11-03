# setline 与路由

setline 仍是可选的本地 HTTP 代理，但 **basctl 不再对接 setline**。

basctl 只负责本机实例生命周期：

```text
basctl start / stop
  → 分配端口
  → 启动/停止实例
  → 写 servers/<name>/server.info
```

basctl：

- 不连接 setline admin
- 不推送路由
- 不读取 setline 路由表
- 不调用 basagent
- 不触发上报

## 路由来源

basagent 通过已有的 WebSocket 通道上报 `report:bas`，其中包含：

```text
instances[].httpPort
instances[].webapps[].context / urls
```

bashub 据此提供：

```text
GET /api/bashub/config/{project}/routes?ip=<本机IP>
```

setline-agent 在 `pull` 时下载该机器的 routes，缓存为：

```text
<agent.output>/routes.json
```

然后由 `setline-agent render` 生成 nginx/haproxy 片段。

完整链路：

```text
basagent report:bas
  → bashub AgentSession.basReport
  → setline-agent pull routes
  → routes.json
  → setline-agent render
  → nginx/haproxy fragment
```

## setline 服务

`setline.service` 仍保留，但只用于需要其数据面能力的场景。

如果部署方式是：

```text
haproxy/nginx + setline-agent
```

则不需要启动 `setline.service`。

## 与 basctl 的关系

basctl 和 setline / basagent 没有调用关系：

- basctl 不知道 setline 是否存在
- basctl 不知道 basagent 是否在线
- 本地 `basctl start` / `stop` 不会触发 `report:bas`

如果 basctl 是被人直接调用的，而 basagent 没有在运行或没有收到上报，
运行状态会在下一次 agent 上报后才进入 bashub。

这是有意为之：basctl 是一个工具，不是 agent 的 supervisor，也不负责通知 agent。

## server.xml 中的 setline 字段

`<setline>` / host 的 `setline-listen-port` / `setline-admin-port` 是旧部署兼容字段，
不再参与 basctl 的路由推送。新部署不需要依赖它们。
