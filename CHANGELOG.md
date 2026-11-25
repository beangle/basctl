# Changelog

## v0.0.5 (2026-11-25)

- **主机信息上报**：`report:os` 增加 `os.prettyName`、`os.id`、`os.versionId` 和
  `cpu.model`；`name` 继续提供发行版展示名，供 bashub 的 Host「从 Agent 更新」回填
  发行版与 CPU 型号。
- **修复安装包 basctl.env**：DEB/RPM 在 `/etc/bas/conf/basctl.env` 缺失或为空时从
  `/usr/share/bas/basctl.env` 初始化，模板缺失则安装失败；DEB 构建阶段先确认模板已
  暂存且非空，避免产出不完整安装包。
- **移除过时 sudoers requiretty 设置**：新版 sudo（如 Ubuntu 26）已不识别
  `!requiretty`，会报 `unknown setting`；`/etc/sudoers.d/basproxy` 不再写该行，
  现代 sudo 默认不要求 TTY。

## v0.0.4 (2026-11-23)

- **修复 root helper 的 runuser 参数**：CentOS 7 的 `runuser` 不允许 `-s` 与 `-u` 同时使用；
  改为 `runuser -u micdn -- /bin/sh -c ...`，避免 micdn 停止时 apply 失败。
- **micdn 配置改为 root oneshot**：basagent 下载 `micdn.xml` 到私有目录，触发
  `basmicdn-apply.service`；root helper 用 `micdn --check` 校验、原子安装
  `/etc/micdn/micdn.xml` 并 restart，失败恢复旧配置。移除对 `/admin/config` 的依赖。
- **真实服务状态上报**：`report:os` / `report:health` 增加 `micdn` 和
  `proxyState.haproxy/nginx`，来自 `systemctl is-active`，监控不再用 agent 在线代替服务在线。
- **启动就绪判定**：`basctl start` / `service:start` 等待进程存活且 HTTP 端口 LISTEN
  （最多 30 秒），不再把刚 spawn 当成已启动。
- **删除部署后清理 server.xml**：远端不再包含本机 bas server 时，basagent 删除旧
  `server.xml`，避免已删除的部署继续出现在监控的 `declared` 中。

## v0.0.3 (2026-11-20)

- **远程配置迁到 `/etc`**：`basctl.env` 从 `$BAS_HOME/conf` 迁到
  `/etc/bas/conf/basctl.env`（root:beangle 0640）；systemd 只读这一处，不再读取
  `/etc/sysconfig/basagent`、`/etc/default/basagent`。
- **`basctl init` 不再写 `basctl.env`**：未设置 `BAS_PRINCIPAL`/`BAS_TOKEN` 时只提示创建
  `/etc/bas/conf/basctl.env`；`bin/env.sh` 默认加载该文件，源码/自定义目录用
  `BAS_ENV_FILE` 覆盖。
- **不提供旧路径回退**：程序不读取 `/var/lib/bas/conf/basctl.env`；升级时需自行迁移文件。
- **本机开机自启**：`<server>` 增加 `<auto-start>` 子元素和 `wait-for`（本机 ref / 外部 url / tcp）；
  `basctl autostart` 按依赖逐个启动本机节点，basagent 启动时在有 server.xml 的情况下调用它。
  不引入 `autostart` 属性、`autostart-order` 或 `depends-on`。
- **删除部署节点后清理本地配置**：远端 `server.xml` 不再包含本机 bas server 时，basagent
  删除本地旧 `server.xml`，避免已删除的 server 继续出现在 `declared`/监控中；proxy/micdn-only
  agent 仍可无配置运行。
- **agent 可无 server.xml 运行**：`basagent pull` 发现远端配置没有本机 bas server 时，不安装
  server.xml（并清理无效的旧空文件）；`basagent.service` 不再要求该文件存在，micdn/proxy 节点
  可以只保留 agent 身份与通道。
- **移除过时 sudoers requiretty 设置**：新版 sudo（如 Ubuntu 26）已不识别 `!requiretty`，会报
  `unknown setting`；`/etc/sudoers.d/basproxy` 不再写该行，现代 sudo 默认不要求 TTY。
- **安装包补齐 basctl.env**：DEB/RPM 仍把模板装到 `/usr/share/bas/basctl.env`，`postinst/%post`
  在 `/etc/bas/conf/basctl.env` 缺失**或为空**时重新生成；模板缺失时安装直接失败并报明原因。
- **启动就绪判定**：`basctl start` / `service:start` 现在等待进程存活且 HTTP 端口开始 LISTEN
  （最多 30 秒），避免进程启动 1–2 秒后退出却被报告为已启动。
- **micdn 配置投递**：`micdn:reload` 不再调 `/admin/reload`；agent 用 Project key 拉取
  `micdn.xml` 到 `/var/lib/bas/micdn/`，触发 root oneshot `basmicdn-apply.service`，由 helper
  校验、原子安装并 restart micdn。agent 不写 `/etc/micdn`，也不把 token 交给 helper。
- **修复 `micdn:reload` 下载鉴权**：micdn.xml 端点只接受 Project key，basagent 不再误用
  握手用的 `<project>:<key>`，否则会报 `micdn-download-failed`。
- **micdn 停止时可投递配置**：root oneshot 先校验 `micdn.xml`，再原子替换并 restart
  `micdn.service`；HTTP `/admin/config` 已移除，不依赖管理端口，失败恢复旧配置。
- **`basctl proxy` 改为只应用本地 bundle**：`apply` 必须给 `--bundle=FILE`，不再读取
  `BAS_PRINCIPAL`/`BAS_TOKEN` 或下载；远程下载和触发统一由 basagent 负责。
- **新增 `proxy:apply`**：basagent 用 Project token 下载代理 bundle，再通过固定 sudoers 规则触发
  `basproxy-apply@<engine>.service`；root helper 校验路径后调用 `basctl proxy apply --bundle`。
  安装包附带 `/usr/libexec/basproxy-apply`、`/usr/libexec/basmicdn-apply`、模板 unit 和
  `/etc/sudoers.d/basproxy`。
- **CentOS 7 权限**：systemd 219 不传 unit detail，polkit 无法限定 unit；改用只允许
  `bas` 启动两个固定 proxy unit 和 `basmicdn-apply.service` 的 sudoers 规则，并关闭
  basagent 的 `NoNewPrivileges`，不放开任意 `systemctl`。
- **卸载保留 `basctl.env`**：安装包只把模板放到 `/usr/share/bas/basctl.env`，
  `/etc/bas/conf/basctl.env` 由 `postinst`/`%post` 在缺失时创建，不再作为 deb conffile 或 rpm
  `%files` 条目；卸载、重装、升级都不会删除或覆盖主机级配置。模板只用于首次安装时初始化。
- **节点版本上报**：`report:os` 增加 `proxy.haproxy` / `proxy.nginx`，取本机 `-v` 输出；未安装为空串，
  控制台在线节点页据此显示代理版本。
- **文档拆分**：新增 `docs/basagent.md`；basctl 的 features/usage/proxy/start/server-info/run
  只保留本地 CLI 内容，basagent 的通道、配置投递、代理触发和排障集中到 agent 文档。
- **测试**：`dub test` 通过 153 个用例；新增 auto-start / wait-for 解析与 `basctl autostart`
  回归测试。

## v0.0.2 (2026-11-17)

- **远程凭证改为环境变量**：删除 `basctl.conf` 的 `[remote]` 段，改用
  `BAS_PRINCIPAL=project@url` 和 `BAS_TOKEN`；`pull` 不再接受 `--file`，启动拉取失败即失败，
  不做本地兜底。
- **配置模板**：安装包改为下发 `basctl.env`，systemd 通过 `EnvironmentFile` 加载；
  `${bas_remote_url}` / `${bas_remote_token}` 由环境变量展开。
- **控制通道**：`basagent` 只从环境变量读取 Project 和 token，启动时先拉取 server.xml。
- **`basctl proxy`**：新增 `apply` / `status` 子命令，从 bashub 下载代理 ZIP bundle，
  校验 manifest 和各文件 SHA-256，安装后执行 `haproxy -c` / `nginx -t` 和
  `systemctl reload`。不读取 `conf/server.xml`，代理节点只依赖 `BAS_PRINCIPAL` /
  `BAS_TOKEN`。
- **ZIP bundle 应用**：支持引擎区分的 `config/haproxy.cfg` / `config/nginx.conf`、证书、
  私钥、HAProxy 路由 map 和 `manifest.json`；HAProxy 安装时合并证书和私钥，Nginx 分文件安装；
  失败自动恢复旧文件。
- **本地应用模式**：`--bundle=FILE` 直接应用已下载的 ZIP，可配合 `--dry-run` 在不联网时验证。
- **部署位置发现**：按 `--config`、`nginx -V` 的 `--conf-path`、systemd `ExecStart` 和常见路径
  查找代理配置；`--service` 覆盖 reload 的服务名。不安装 systemd service，也不创建定时器。
- **证书随代理目录**：证书安装到配置文件所在目录的 `certs/`（如 `/etc/haproxy/certs`、
  `/etc/nginx/certs`），并通过 `cert-dir` 让 bashub 按同一路径渲染配置。
- **服务未运行时启动**：`proxy apply` 在目标服务 inactive 时执行 `start`，运行中才 `reload`。
- **jstart 预检**：`start` 在删除实例目录前检查 jstart 是否存在，缺失时给出明确错误。
- **依赖**：对齐 `vibe-stream` 1.5 版本范围。
- **测试**：`dub test` 通过 151 个用例；移除依赖真实网络和进程环境的 agent report 用例。

## v0.0.1 (2026-11-07)

- **首个公开版本**：`basctl` 与 `basagent` 以同一版本号发布，均以 D + LDC 构建为原生
  可执行文件。`basctl` 提供本地控制面，`basagent` 提供配置拉取与出站控制通道。
- **`server.xml` 驱动部署**：把一个 `<bas>` 配置解析为 farm / server / webapp，支持
  `gav://`、`http(s)://` 与本地路径；按实例生成独立目录和 jstart launch spec，并渲染
  容器配置。
- **完整的本地生命周期命令**：`version`、`banner`、`status`、`logs`、`init`、`make`、
  `resolve`、`start`、`stop`、`run`、`doctor`、`firewall`；`make` 同时承担批量准备与
  jstart `[engine] init` creator 两种模式。
- **可复现的运行态**：`server.info` 记录实例 pid、端口、引擎与 webapp；`<server http="0">`
  在端口区间内顺序分配并持久化，`status` / `stop` / agent 都以该文件为准；日志支持尾部、
  跟随与滚动续读。
- **jstart 集成**：`make` / `resolve` / `start` / `run` 把构件解析、下载与 exec 交给
  `jstart`；支持 release / snapshot 仓库、仓库 token、offline 模式，以及
  `tomcat-server`、`tomcat`、`undertow`、`jetty`、`native` 五类引擎。
- **basagent 控制通道**：从 `basctl.conf` 的 `[remote]` 读取地址与凭证，支持显式
  `pull`、一次性 `report` 与常驻 WebSocket；上报主机家底、磁盘水位和实例健康，执行固定的
  日志 / 启停原语，并支持同组 agent 的 master 选举与迁移。
- **发行与部署**：提供 deb / rpm 打包脚本、systemd unit、logrotate 配置、容器镜像构建；
  标准安装预置 `/var/lib/bas` 控制树，`basctl.conf` 只在缺失时生成且升级/卸载不覆盖。
- **测试**：`dub test` 覆盖配置、解析、spec、启停、端口、健康上报、控制通道等模块，
  共 157 个用例通过。
