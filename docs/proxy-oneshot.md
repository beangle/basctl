# Proxy 落盘的权限边界：basagent 为什么能写配置、重启代理

本文只解释 **basagent 如何在不获得 root shell 的前提下，触发一次以 root 身份执行的代理应用**。
bundle 内容、`basctl proxy apply` 的校验细节和 ZIP 格式见 [proxy.md](proxy.md)；
agent 的通道与下载流程见 [basagent.md](basagent.md)。

## 职责划分

| 角色 | 身份 | 负责 | 不负责 |
|---|---|---|---|
| bashub | 中心服务 | 生成代理 bundle | 不接触目标机文件系统 |
| basagent | `bas:beangle` | 下载 bundle、写请求文件、触发固定 unit | 不写代理配置、不读 token 以外凭证、不启动任意 unit |
| sudoers | root 配置 | 只放行两个 proxy unit 和 `micdn.service` 的固定 `systemctl start` | 不授予通用 sudo |
| `basproxy-apply@.service` | root oneshot | 作为权限边界启动 helper | 不长期运行、不提供网络接口 |
| `/usr/libexec/basproxy-apply` | root | 校验请求文件，调用 `basctl proxy apply` | 不接受 URL、路径或任意 engine |
| `basctl proxy apply` | root | 校验 bundle、写配置/证书、语法检查、reload/回滚 | 不下载、不理解项目拓扑 |

核心结论：**写 `/etc/haproxy`、`/etc/nginx` 和重启代理的是 root helper，不是 basagent。**
basagent 只被允许“按固定名字启动一个 root oneshot unit”。

## 执行链

```text
管理台点击「应用 proxy」
  → bashub 校验登录会话，生成 ZIP bundle
  → basagent（bas）用 Project token 下载到 /var/lib/bas/proxy/<engine>.zip
  → basagent 写 /var/lib/bas/proxy/<engine>.endpoint
  → basagent 执行：
       sudo -n /usr/bin/systemctl start basproxy-apply@<engine>.service
  → systemd（root）启动 oneshot unit：
       /usr/libexec/basproxy-apply <engine>
  → helper 校验固定目录、属主、权限、路径、engine
  → helper 执行：
       /usr/bin/basctl proxy apply --engine=<engine> --bundle=<zip>
  → basctl 校验 manifest/hash、写配置、haproxy -c / nginx -t、reload/start
  → helper 把结果写到 /var/lib/bas/proxy/<engine>.result
  → basagent 读取 result，回传管理台
```

`sudoers` 对本文这条链路只涉及两个 proxy unit（同一文件还放行 `micdn:reload` 启动
`micdn.service`，不属于 proxy 应用链）：

```sudoers
Defaults:bas !requiretty
Cmnd_Alias BASPROXY_APPLY = /usr/bin/systemctl start basproxy-apply@haproxy.service, /usr/bin/systemctl start basproxy-apply@nginx.service
bas ALL=(root) NOPASSWD: BASPROXY_APPLY
```

因此 `bas` 不能执行 `sudo bash`、不能 `systemctl start sshd`、不能给固定命令追加参数；
它只能启动两个预先定义好的 unit。

## 为什么用 oneshot，而不是让 basagent 直接 sudo

如果直接授权：

```text
bas ALL=(root) NOPASSWD: /usr/bin/basctl proxy apply ...
```

就必须允许 `bas` 控制 `--bundle`、`--engine` 等参数，授权面会随参数扩展。
当前设计把可变部分留在 **bas 自有目录中的请求文件**，root 侧只接受：

- 固定 engine：`haproxy` / `nginx`；
- 固定路径：`/var/lib/bas/proxy/<engine>.zip`；
- 固定 endpoint 文件：`/var/lib/bas/proxy/<engine>.endpoint`。

systemd unit 是 root 进程，`ExecStart` 里没有用户输入；helper 再做一次路径和属主校验。
这样 root 权限只存在于一个短生命周期的 oneshot 中，不形成常驻 root agent。

## 请求文件的安全校验

helper 在调用 basctl 前检查：

- `/var/lib/bas/proxy` 是目录且不是 symlink；
- `<engine>.zip` 存在、属主为 `bas`、权限 `0600`、不是 symlink；
- `<engine>.endpoint` 存在、属主为 `bas`、权限 `0600`、不是 symlink；
- bundle 的 realpath 仍在 `/var/lib/bas/proxy` 下；
- endpoint 只允许字母、数字、`.`、`_`、`-`，长度受限；
- engine 只允许 `haproxy` / `nginx`。

bundle 由 basagent 下载，token 不传给 root helper；helper 不联网，也不读取 `BAS_TOKEN`。
root 只信任“bas 放进固定目录且满足权限要求的文件”，不会跟随 `bas` 放置的 symlink 写到其他路径。

## 代理进程的生命周期

`basproxy-apply@.service` 是 `Type=oneshot`：

- `systemctl start` 会同步执行 helper，结束后 unit 变为 `inactive (dead)`；
- 它不负责长期运行 HAProxy/Nginx；
- 真正的代理进程由 `basctl proxy apply` 内部的 `systemctl reload`（未运行时 `start`）管理。

所以“启动 oneshot”只表示“执行一次应用动作”，不表示“用 oneshot 托管代理进程”。

## 并发与失败

- helper 用 `/run/basproxy-<engine>.lock` + `flock -n` 保证同一 engine 同时只执行一次；
- basctl 先校验 ZIP 和每个文件的 SHA-256，再写临时文件、语法检查、原子替换；
- 语法检查或 reload 失败时恢复旧配置和证书；
- 结果写入 `<engine>.result`；agent 读取后回传，失败时管理台展示 detail；
- 没有 bundle、没有权限、helper 缺失、unit 启动失败都失败关闭，不会退化成直接写配置。

## 环境与部署前提

节点需要：

- `bas` 用户、`beangle` 组；
- `sudo`，以及 `/etc/sudoers.d/basproxy`（`0440 root:root`）；
- `basagent.service` 以 `bas` 运行，并设置 `NoNewPrivileges=false`，否则 sudo 无法提升；
- `/usr/libexec/basproxy-apply`（root:root，可执行）；
- `basproxy-apply@.service`（root oneshot）；
- `/usr/bin/basctl`；
- `haproxy` 或 `nginx`，以及可写的配置/证书目录。

不再使用 polkit 规则。CentOS 7 的 systemd 219 不向 polkit 传递 `unit` detail，无法安全地按 unit 限制；
sudoers 的固定命令方案在 EL7/8/9 行为一致，因此作为唯一实现。

## 手工验证

```sh
# 查看授权范围
sudo -l -U bas

# 手工触发：没有 bundle 时 unit 会失败，但不应要求密码
sudo -u bas sudo -n /usr/bin/systemctl start basproxy-apply@haproxy.service

# 查看结果
systemctl status basproxy-apply@haproxy.service -l --no-pager
journalctl -u basproxy-apply@haproxy.service -b -n 100 --no-pager
cat /var/lib/bas/proxy/haproxy.result
```

手工直接 `systemctl start` 不会下载 bundle，只适合验证授权边界；真实应用必须从管理台发起。
