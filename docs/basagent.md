# basagent

`basagent` 是安装在同一发行包里的**远端执行客户端**，与本地 CLI `basctl` 分工不同：

```text
bashub（控制台）
  → basagent（常驻，bas:beangle）
      → 本机服务：实例启停 / 日志 / proxy root helper / micdn 本地接口
  ← 主机与实例现状、执行结果

basctl：本地命令行，独立使用，不依赖 basagent
```

## 身份与安装

| 项目 | 说明 |
|---|---|
| 进程 | `basagent.service`（systemd 常驻） |
| 账号 | `bas:beangle`，不 root |
| `BAS_HOME` | `/var/lib/bas` |
| 凭证 | `/etc/bas/conf/basctl.env`，`root:beangle 0640` |
| 日志 | `/var/log/bas/agent/console.out`（`agent:log` 读取） |

`basctl init` 只铺本地控制脚本，不创建 `basctl.env`；远程身份由运维配置。源码/自定义目录可用
`BAS_ENV_FILE` 指向自己的环境文件，但 systemd 固定读 `/etc/bas/conf/basctl.env`。
`basagent.service` 不再要求 `server.xml` 存在，micdn/proxy 节点可以只有 agent 配置。

## 凭证

```sh
BAS_PRINCIPAL=org.example@https://hub.example.com
BAS_TOKEN=<Project.key>
```

- `BAS_PRINCIPAL` 的 project 是 bashub 的 `org.name`，url 是控制台根地址。
- 两项必须同时存在；只配一项直接失败。
- token 只在 basagent 进程和 `/etc/bas/conf/basctl.env` 中，不写进 micdn、server.xml 或日志。

## 启动时做什么

1. 用 Project token 拉取 `GET /api/bashub/config/{project}/server`；如果返回的配置没有本机
   可运行的 bas server，就**不安装** `server.xml`（也不留下临时文件），agent 以空实例集继续
   运行。只有存在本机 server 时才原子替换 `$BAS_HOME/conf/server.xml`。
2. 拉取失败但本地已有 `server.xml`：按离线正常情况直接使用本地文件，不告警；没有本地文件
   时不调用 autostart。
3. 本地有 `server.xml` 时调用 `basctl autostart`：只启动带 `<auto-start>` 的本机节点，按
   `wait-for ref` 排序并逐个启动；外部 `wait-for url/tcp` 有界等待。
4. 拨出站 WebSocket 到
   `/api/bashub/monitor/agents/{project}/channel`，发送 `hello`、主机与实例快照。
5. 按 hub 节奏回保活、`report:health`、`report:now`。

## 固定指令

basagent 只执行白名单原语，不拼 shell，不接收任意命令/URL/路径：

| 原语 | 作用 |
|---|---|
| `log:read` / `agent:log` | 读实例或 agent 日志区间 |
| `service:start` / `stop` / `restart` | 调 `basctl` 启停本机 `server.xml` 里的实例；start/restart 前先拉一次 server.xml |
| `micdn:reload` | 用 Project key 拉取 micdn.xml，POST 到本机 `127.0.0.1:8888/admin/config`；micdn 自己校验、原子写文件并 reload |
| `proxy:apply` | 用 Project token 下载代理 bundle，触发本机受 polkit 限制的 `basproxy-apply@<engine>.service`；root helper 再调 `basctl proxy apply --bundle` |
| `config:refresh` / `report:now` / `report:health` | 重新拉配置 / 立即上报 / 返回健康摘要 |

协议细节见 [channel-protocol.md](channel-protocol.md)；常驻、排障和凭证配置见
[channel.md](channel.md)。

## micdn 配置投递

`micdn:reload` 的完整链路：

```text
GET /api/bashub/micdn/{project}/micdn.xml   (Bearer <Project.key>)
  → POST 127.0.0.1:8888/admin/config
  → micdn 校验、原子写自己的 micdn.xml、reload
```

basagent **不写** `/etc/micdn`，也不把 `BAS_TOKEN` 交给 micdn；micdn 是唯一写自己配置的人。
失败时旧文件和旧 router 都不变。

## 代理应用

`proxy:apply` 由管理台触发，目标 IP 来自 endpoint 的 `ips`。basagent 只负责下载 bundle 和触发
固定 unit；真正落盘/reload 由 root helper 执行。

### 执行链

```text
bashub 管理台（登录会话）
  → basagent（bas:beangle，无权）
  → 下载 bundle 到 /var/lib/bas/proxy/<engine>.zip（使用 Project token，不交给 root）
  → 写 /var/lib/bas/proxy/<engine>.endpoint
  → systemctl start basproxy-apply@<engine>.service（polkit 仅授权这一种 unit）
  → root-owned /usr/libexec/basproxy-apply 校验路径并执行
       basctl proxy apply --engine=<engine> --bundle=<path>
  → 校验 / 原子替换 / reload / 失败回滚
  → 写 /var/lib/bas/proxy/<engine>.result，agent 读取后回给 hub
```

bashub 只发固定动作（`engine` + `endpoint`），不接受任意命令、URL、service 名或配置路径；
bundle 下载由 agent 完成，root helper 不联网，也不读取 `BAS_TOKEN`。

### CentOS 7 与 polkit

CentOS 7 的 polkit 是 **0.112**，支持 `/etc/polkit-1/rules.d/*.rules` 的 JavaScript 规则；
systemd 219 也支持模板 unit。规则只允许 `bas` 用户 `start`
`basproxy-apply@haproxy.service` / `basproxy-apply@nginx.service`：

```js
polkit.addRule(function(action, subject) {
  if (action.id !== "org.freedesktop.systemd1.manage-units")
    return;
  var unit = action.lookup("unit");
  var verb = action.lookup("verb");
  if (subject.user === "bas" && verb === "start" &&
      (unit === "basproxy-apply@haproxy.service" ||
       unit === "basproxy-apply@nginx.service"))
    return polkit.Result.YES;
});
```

不使用 `.pkla`：它只能按 action 授权，无法把 `org.freedesktop.systemd1.manage-units` 限定到固定
unit；放行它会允许 `bas` 管理所有 systemd unit。没有 JS 规则的环境应失败关闭，而不是加宽 `.pkla`
或 sudo。

root oneshot unit 只运行 `/usr/libexec/basproxy-apply %i`；helper 校验 bundle 属于 `bas`、权限
0600、非 symlink，使用 `flock` 串行化，再调用 `basctl proxy apply --bundle`。

## 命令

```sh
sudo -u bas -H basagent pull /var/lib/bas    # 手工拉取 server.xml
sudo -u bas -H basagent report /var/lib/bas/conf/server.xml
sudo systemctl start|stop|restart basagent.service
sudo -u bas -H tail -f /var/log/bas/agent/console.out
```

## 边界

- `basagent` 是远端命令执行者；`basctl` 是本地 CLI。**`basctl` 不调用 `basagent`**。
- `basagent` 需要本地操作时调用 `basctl`（例如 root helper 的 `basctl proxy apply`），方向是
  `agent → basctl`，不是反过来。
- 不 root、不做 supervisor、不自动重启实例；实例生命周期仍由 `basctl start/stop` 负责。
- 不接收任意 service 名、配置路径或 URL；只做固定原语和固定本机端点。

## 安全

- 只允许出站连接；控制面不暴露入站端口。
- 管理端点固定 localhost；proxy 只允许 polkit 授权的固定 unit。
- 失败关闭：缺 token、缺 helper、polkit 未授权都返回失败，不回退到 sudo 或宽泛权限。
