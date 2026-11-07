# Changelog

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
