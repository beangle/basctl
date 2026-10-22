# 汇报通道（basagent → bashub）

basagent 主动拨一条出站 WebSocket 到控制台（bashub），把**这台机器的现状**报上去，并接收控制台下发的
固定指令。现状 = 主机家底（CPU / 内存 / 磁盘）+ 本机活着的 bas 实例；指令 = 立即上报、取日志区间、
启动 / 停止 / 重启实例。

协议本身（信封、原语表、鉴权、节拍）见 [channel-protocol.md](channel-protocol.md)——**那份是唯一权威**，
本文只讲怎么用、什么时候用、坏了怎么办。

## 启用

地址、Profile 和凭证都放在与 `server.xml` 同目录的 `conf/basctl.conf`，与 `pull` 完全共用：

> `basctl init` 会生成带注释的模板；把 `[remote]` 的三项填上即可。

```ini
[remote]
url = https://hub.example.com
profile = openurp.prod
token = 9f8e7d6c5b4a39281706f5e4d3c2b1a0
```

- `[remote] url` / `profile` / `token` 三项齐全才启用；`basagent` 拼出
  `https://hub.example.com/api/bashub/monitor/agents/<profile>/channel` 拨号，`http(s)` 自动
  换成 `ws(s)`。
- `token` 同时用于 `pull` 和通道握手，取值是 bashub 的 `Profile.key`。在 bashub 的配置详情里可以查看，
  发送时拼成 `<profile>:<Profile.key>`；`POST /api/bashub/config/profiles/{id}/reset-key` 可以
  重置（重置后旧的拉取与通道连接一起失效）。
- `server.xml` **不再**保存通道地址或凭证；旧文件里遗留的 `<hub>` 元素会被直接忽略。
- 不再读取 `bas_remote_url` 等环境变量。

## 命令

| 命令 | 做什么 | 什么时候用 |
|---|---|---|
| `basagent report [server.xml]` | 连一次、发 `hello` + 两份上报、断开；报上去了退出码 0 | 手工对一次账；脚本 / cron |
| `systemctl start basagent.service` | 常驻：连上就报，之后按 60s 周期上报、回保活、执行固定指令（读日志 / 启停实例），断线 10s 后重连 | 生产机由系统级 systemd 管理，账号固定为 `bas:beangle` |
| `bin/bas.sh pull` | 显式拉取一次 `conf/server.xml`（底层调用 `basagent pull`） | 需要从 bashub 更新配置时 |

`basctl start` / `basctl stop` 与 `bin/start.sh` / `bin/restart.sh` 只做本地动作，不拉配置、
也不顺带上报。常驻 agent 按周期上报；远程 `service:start` / `service:restart` 执行前会先拉取一次
配置，拉取失败就返回失败而不执行动作；`service:stop` 不拉取。

本地看同一个日志：`basctl logs <实例> -f`——它和 `log:read` 走**同一份读法**
（`src/bas/logs.d`），所以控制台上看到的行号与本地 `-n` 数出来的是同一个。
标准安装的实际日志根是 `/var/log/bas`，`/var/lib/bas/logs` 是指向它的符号链接。
`agent:log` 读取固定的 `/var/log/bas/agent/console.out`，用于 agent 自身排错。

## 上报什么、不报什么

- **是**：主机家底与水位（CPU 核数与负载、内存总量与可用、磁盘各挂载点的容量），以及本机
  `servers/<name>/server.info` 里活着的实例（id / pid / 引擎 / 端口 / webapp / 对外 url）。
- **不是**：不重新解析 `server.xml`（那是**意图**；报的是**事实**），不碰 setline 的流量与健康，
  不做通用监控（不替代 Prometheus），也没有远程 shell——能下发的动作是固定的那几个原语。
- 取不到的字段就**留空**，不伪造：Windows 开发机上没有 `/proc`，那些项就是「不可用」。

## 认证与失败的表现

| 现象 | 多半是 | 怎么办 |
|---|---|---|
| `warning: remote is not configured` | `basctl.conf` 缺字段或文件不在 `server.xml` 同目录；`basagent` / `pull` 视为未启用，正常退出 | 需要通道时补全 `[remote]` 三项，见上面的样例 |
| `no snapshot published: wss://…` | 地址不对 / 控制台不可达 / 网络不通 | 先确认 `bin/bas.sh pull` 能通；地址看 `conf/basctl.conf` |
| 常驻 agent 反复重连 | 同上，或 token 被重置过 | 更新 `basctl.conf` 的 token 后重启 agent |
| 控制台看不到这台机器 | 通道没连上，或 profile 名不对 | 看 `/var/log/bas/agent/console.out` 的 `channel:` 行；确认路径里的 profile 与 bashub 的配置名一致 |
| `service:*` 返回 `start-failed` / `prepare-failed` | 实例启动或依赖解析失败 | 控制台先看结果里的 `detail` / `logTail`；完整内容用 `log:read` 或 `basctl logs` |

## 常驻 agent 怎么跑

```bash
# 前台跑（调试用，Ctrl-C 退出）
sudo -u bas -H basagent /var/lib/bas/conf/server.xml

# 生产：RPM/DEB 安装的 systemd 服务
sudo systemctl start basagent.service
sudo systemctl stop basagent.service
sudo systemctl restart basagent.service
sudo systemctl status basagent.service
```

服务 unit 固定使用 `User=bas`、`Group=beangle`、`BAS_HOME=/var/lib/bas`；basagent
自身也会拒绝 root。PID 由 systemd 管理，日志追加到 `/var/log/bas/agent/console.out`；
`/etc/logrotate.d/bas` 在文件达到 10 MiB 时用 `copytruncate` 轮转，保留 8 份压缩历史。
systemd 不读取 `bas` 用户的 `.bashrc`；需要自定义 JDK 或 OpenSSL 时，把
`JAVA_HOME` / `PATH` / `LD_LIBRARY_PATH` 写进 `/etc/sysconfig/basagent`
（Debian 系也可用 `/etc/default/basagent`），再重启服务。

agent 只做「上报 + 固定指令」，**不做 supervisor**：实例崩了不会自动重启（这条一直不变），
也没被超时或坏消息弄退出的风险——它宁可重连也不退出。`service:stop` / `service:restart`
由控制台显式触发、二次确认，不会因为实例退出而自动补做。

## 升级

RPM/DEB 升级时会执行 `systemctl try-restart basagent.service`，让正在运行的 agent
切换到新二进制。配置和日志目录不会被安装包覆盖：

```bash
sudo -u bas -H basctl init --force /var/lib/bas
sudo systemctl restart basagent.service
```

`basctl init --force` 刷新 `bin/*.sh`；`basctl.conf` 与 `server.xml` 不会被覆盖。

从旧版 `bas.sh agent-start` 迁移时，先用旧 `BAS_HOME` 里的 `bin/bas.sh agent-stop`
（或旧 PID 文件）停掉手工启动的 agent，再启动 systemd 服务；同一个 profile 只允许一条
连接，两份 agent 同时在跑会互相踢下线。

## 与 setline 的分工

|  | setline | 汇报通道 |
|---|---|---|
| 管什么 | 反代的**路由**（谁把哪些前缀转到哪个端口） | 节点的**现状**（机器家底 + 实例清单） |
| 谁读它 | 反代（haproxy / nginx，经 setline 的读接口） | 控制台（bashub 的内存登记册） |
| 地址从哪来 | `server.xml` 的 `<setline port>` | `conf/basctl.conf` 的 `[remote]` |
| 失败的影响 | 路由不更新，实例本身没事 | 控制台看不到现状，实例本身没事 |

两者都不常驻在 basctl 里（setline 是独立进程，通道靠 `basagent`），互不依赖。
