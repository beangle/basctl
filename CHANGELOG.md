# Changelog

## v0.0.3 (unreleased)

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
- **agent 可无 server.xml 运行**：`basagent pull` 发现远端配置没有本机 bas server 时，不安装
  server.xml（并清理无效的旧空文件）；`basagent.service` 不再要求该文件存在，micdn/proxy 节点
  可以只保留 agent 身份与通道。
- **micdn 配置投递**：`micdn:reload` 不再只调本机 `/admin/reload`；agent 用 Project token 拉取
  `micdn.xml`，POST 到本机 `/admin/config`，由 micdn 自己校验、原子写文件并 reload。agent 不写
  micdn 目录，也不把 token 交给 micdn。
- **`basctl proxy` 改为只应用本地 bundle**：`apply` 必须给 `--bundle=FILE`，不再读取
  `BAS_PRINCIPAL`/`BAS_TOKEN` 或下载；远程下载和触发统一由 basagent 负责。
- **新增 `proxy:apply`**：basagent 用 Project token 下载代理 bundle，再触发受 polkit 限制的
  `basproxy-apply@<engine>.service`；root helper 校验路径后调用 `basctl proxy apply --bundle`。
  安装包附带 `/usr/libexec/basproxy-apply`、模板 unit 和 CentOS 7 可用的 polkit JS 规则。
- **CentOS 7 polkit**：使用 polkit 0.112 支持的 JavaScript `rules.d` 规则，只允许 `bas` 启动固定
  proxy unit；不使用无法限定 unit 的宽泛 `.pkla`。
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
