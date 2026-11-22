# micdn 配置投递：root oneshot 写配置并重启

本文说明 `micdn:reload` 为什么不经过 `admin/config`，以及没有 root shell 的 basagent
如何安全地替换 `/etc/micdn/micdn.xml`。

## 责任链

```text
bashub 管理台
  → basagent（bas:beangle）
       下载 micdn.xml 到 /var/lib/bas/micdn/micdn.xml，权限 0600
  → sudo -n systemctl start basmicdn-apply.service
  → systemd 启动 root oneshot：/usr/libexec/basmicdn-apply
  → micdn --check -f /var/lib/bas/micdn/micdn.xml
  → 备份旧配置、原子替换 /etc/micdn/micdn.xml
  → systemctl restart micdn.service
  → 检查 active，失败则恢复旧配置并重启
  → 写 /var/lib/bas/micdn/apply.result
  → basagent 读取 result，回传管理台
```

basagent 不写 `/etc/micdn`，不传 token 给 helper；helper 不联网、不接受 URL、端口或任意路径。

## 为什么不再 POST /admin/config

旧链路要求 micdn 已经运行并且管理端口可达，因此：

- micdn stopped 时无法投递；
- 需要猜测/读取 `listen` 端口，修改端口时尤其不可靠；
- 配置投递依赖 HTTP 服务的健康状态。

one-shot 直接替换文件并重启，不依赖 micdn 当前是否运行，也不需要知道管理端口。

HTTP 配置投递 `/admin/config` 已移除。

## 安全边界

- 请求文件固定为 `/var/lib/bas/micdn/micdn.xml`，必须是 `bas` 所有、`0600`、非 symlink；
- helper 只接受这一个固定路径；
- 安装前以 `micdn` 身份执行 `micdn --check -f ...`，只解析验证，不监听端口；配置里的 `~`
  因此展开为 micdn 的 passwd home，而不是 root 的 home；
- 新配置先写入 `/etc/micdn` 下的临时文件，再原子 rename；
- 旧配置备份在 `/run`；restart 或 active 检查失败时恢复旧文件并重启；
- 结果文件由 root 写为 `root:beangle 0640`，basagent 只读；
- sudoers 只允许 `bas` 启动 `basmicdn-apply.service`，不能执行任意 systemctl 或写任意路径。

## 失败与并发

- helper 在 `/run/basmicdn-apply.lock` 上加 `flock -n`，同一节点同时只允许一次 apply；
- 配置语法错误：`micdn --check` 失败，目标文件不变；
- micdn 启动失败/未 active：恢复旧配置并重启，返回失败 detail；
- 下载失败、helper 缺失、sudoers 未授权都失败关闭，不回退到直接写文件。

## 部署前提

- `basagent.service` 以 `bas` 运行，`NoNewPrivileges=false`（sudo 提升所需）；
- `/etc/sudoers.d/basproxy` 放行 `systemctl start basmicdn-apply.service`；
- `/usr/libexec/basmicdn-apply`、`basmicdn-apply.service`、`micdn` 的 `--check` 子命令；
- `/var/lib/bas/micdn` 由 basagent 私有创建；`/etc/micdn` 由 root helper 写入；
- `micdn.service` 存在并由 helper restart。
