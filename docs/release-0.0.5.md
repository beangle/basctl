# Release 0.0.5

发布日期：2026-11-25
计划 tag：`v0.0.5`

本版本补齐主机发行版与 CPU 型号上报，并修复 0.0.4 发布后发现的 DEB
`basctl.env` 模板打包问题和新版 sudoers 兼容问题。

## 主机信息上报

`report:os` 的 `os` 增加：

- `prettyName`：与 `name` 相同，明确表示 `/etc/os-release` 的 `PRETTY_NAME`；
- `id`：发行版 ID，如 `debian`、`arch`；
- `versionId`：发行版版本，如 `12`、`2026.11.01`。

`cpu` 增加 `model`，取 `/proc/cpuinfo` 的 `model name`；读不到时为空串。
`name` 字段保持原语义，已有控制台无需修改。bashub 的 Host「从 Agent 更新」
可用这些字段回填发行版与 CPU 型号，不再需要人工录入。

## 安装包

- DEB 构建阶段检查 `/usr/share/bas/basctl.env` 已暂存且非空，缺失时直接失败，
  不再产出缺少模板的安装包。
- DEB `postinst` / RPM `%post` 将 `/etc/bas/conf/basctl.env` 缺失或为空都视为
  未初始化，从包内模板生成；模板不可读时安装失败并报告其路径。
- DEB 在模板处理后再设置目录属主和权限，避免配置目录尚未就绪。

模板仍只用于初始化；`/etc/bas/conf/basctl.env` 不由 deb/rpm 跟踪，升级和卸载
不会覆盖或删除。

## sudoers 兼容性

`/etc/sudoers.d/basproxy` 不再设置 `Defaults:bas !requiretty`。新版 sudo 已移除
该选项，保留会在 Ubuntu 26 等系统上产生 `unknown setting` 警告；现代 sudo
默认不要求 TTY。若节点自行维护过该文件，升级时应同步删除这一行。

## 升级

1. 安装 basctl/basagent 0.0.5 RPM/DEB 或更新 AUR 包；
2. `systemctl daemon-reload && systemctl restart basagent`；
3. 确认 `/etc/sudoers.d/basproxy` 不含 `Defaults:bas !requiretty`；
4. 确认 `/etc/bas/conf/basctl.env` 存在且权限为 `root:beangle 0640`。

## 验证

```text
dub test：153 passed
release 构建：通过
basctl version：basctl 0.0.5
basagent version：basagent 0.0.5
```
