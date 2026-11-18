# basctl proxy

`basctl proxy` 从 bashub 下载完整的代理配置 ZIP，校验后安装到本机并 reload。

它不读取 `conf/server.xml`，也不理解路由拓扑；代理配置完全由 bashub 生成。

## 下载

```bash
sudo basctl proxy apply --engine=haproxy
sudo basctl proxy apply --engine=nginx
```

`basctl proxy` 不安装 systemd service，也不创建定时器。

认证来自：

```text
BAS_PRINCIPAL
BAS_TOKEN
```

接口：

```text
GET /api/bashub/config/{project}/proxy-bundle
  ?engine=haproxy|nginx
  &endpoint=default
```

`engine` 必须与 endpoint 配置的代理引擎一致。

## ZIP 内容

ZIP 文件列表按引擎区分：

```text
haproxy:
  manifest.json
  config/haproxy.cfg
  config/bas-routes.map
  certificate/cert.pem
  certificate/key.pem

nginx:
  manifest.json
  config/nginx.conf
  certificate/cert.pem
  certificate/key.pem
```

| 引擎 | 配置内容 | 证书使用 |
|---|---|---|
| haproxy | `config/haproxy.cfg`，HAProxy 语法；路由在 `config/bas-routes.map` | basctl 将私钥和证书合并为 PEM |
| nginx | `config/nginx.conf`，Nginx 语法 | 证书、私钥分文件安装 |

Micdn 路由和 webapp 路由都会写入 HAProxy 的 `bas-routes.map`；Nginx 仍使用 location：

```text
/asset
/www
/maven
/npm
/native
```

这些路径与所选 endpoint 无关；只要 Project 登记了 Micdn 服务器，就由 bashub 追加。

## manifest.json

```json
{
  "schema": 1,
  "engine": "haproxy",
  "endpoint": "default",
  "files": {
    "config": {
      "path": "config/haproxy.cfg",
      "sha256": "..."
    },
    "certificate": {
      "path": "certificate/cert.pem",
      "sha256": "..."
    },
    "privateKey": {
      "path": "certificate/key.pem",
      "sha256": "..."
    },
    "routeMap": {
      "path": "config/bas-routes.map",
      "sha256": "..."
    }
  }
}
```

`basctl` 按 `role` 选择文件，不直接信任 ZIP 内的任意绝对路径。

## 本地应用

```bash
sudo basctl proxy apply --engine=haproxy --bundle=/tmp/proxy-bundle.zip
```

流程：

```text
解压到临时目录
→ 读取 manifest.json
→ 校验 engine 和 schema
→ 校验每个 role 的 SHA-256
→ 写证书
→ 写配置
→ haproxy -c / nginx -t
→ systemctl reload
→ 失败恢复旧文件
```

`--dry-run` 只打印目标路径，不写文件：

```bash
basctl proxy apply --engine=haproxy --bundle=/tmp/proxy-bundle.zip --dry-run
```

## 部署位置发现

不同发行版/安装方式的 HAProxy/Nginx 配置位置可能不同，`basctl proxy` 会先查找：

1. `--config=FILE` 显式覆盖
2. Nginx 的 `nginx -V` 中的 `--conf-path=`
3. systemd unit 的 `ExecStart` 中的 `-f` / `-c`
4. 常见默认路径

服务名默认与引擎相同，可用 `--service=NAME` 覆盖。

```text
haproxy:
  config: 自动发现，默认 /etc/haproxy/haproxy.cfg
  service: haproxy
  route map: /etc/haproxy/bas-routes.map
  certs:   /etc/haproxy/certs/<endpoint>.bundle.pem

nginx:
  config: 自动发现，默认 /etc/nginx/nginx.conf
  service: nginx
  certs:   /etc/nginx/certs/<endpoint>.pem
           /etc/nginx/certs/<endpoint>.key.pem
```

证书目录取配置文件所在目录下的 `certs/`：basctl 把该目录作为 `cert-dir` 传给 bashub，bundle 内配置与本地安装路径一致。

## ACL 还是 map

当前 HAProxy 使用 ACL：

```text
use_backend prod-farm if { path_beg /bas }
use_backend micdn if { path_beg /maven }
```

暂不使用 `map_beg`。

选择理由：

- bundle 已经由 bashub 完整生成
- 每次应用都会整体替换并 reload
- ACL 少一个 map 文件，少一个运行时路径
- 路由数量在当前规模下可控
- 调试时直接看配置文件即可

所有 `use_backend` 按路径长度从长到短生成，例如：

```text
/api/edu/exam  → 考务后端
/api/edu       → 其他教学后端
```

不能反过来，否则 HAProxy 的首个匹配规则会把考务请求路由到教学后端。

只有在以下情况才考虑 map：

- 路由数量达到数千条
- 需要不 reload 动态更新路由
- 多个 Project 共享同一个 HAProxy 实例

当前方案保持 ACL，避免为少量路由引入 map 文件和状态同步。

## 集中触发与 polkit（规划）

当前 `basctl proxy apply` 需要在节点上以 root 手工执行。后续由 bashub 管理台触发时，
执行链固定为：

```text
bashub 管理台（登录会话）
  → basagent（bas:beangle，无权）
  → 下载 bundle 到 basagent 私有目录（使用 Project token，不交给 root）
  → systemctl start basproxy-apply@<engine>.service（polkit 仅授权这一种 unit）
  → root-owned helper 校验 bundle 路径并执行
       basctl proxy apply --engine=<engine> --bundle=<path>
  → 校验 / 原子替换 / reload / 失败回滚
```

bashub 只发固定动作，不接受任意命令、URL、service 名或配置路径；root helper 不联网，
也不读取 `BAS_TOKEN`。

### 为什么按 CentOS 7 设计

CentOS 7 长期存在于生产环境，必须作为一等目标而不是“兼容补丁”。它的 polkit 是 **0.112**，
已经支持 `/etc/polkit-1/rules.d/*.rules` 的 JavaScript 规则，systemd 219 也支持模板 unit
（`basproxy-apply@.service`）。因此这套方案在 CentOS 7 和现代发行版上使用同一套 JS 规则，
不需要依赖 `polkit-pkla-compat`。

**不使用 `.pkla` 的原因**：0.105 时代的 `.pkla` 只能按 action 授权，无法把
`org.freedesktop.systemd1.manage-units` 限定到某个 unit；允许它等于允许 `bas` 启停/管理
任意 systemd unit，权限过大。CentOS 7 本身有 JS 规则，没必要为了兼容旧格式引入这个宽口子。
如果某个环境确实只有 polkit <= 0.105（没有 JS 规则），`proxy:apply` 应**失败关闭**并提示
部署 root helper/升级 polkit，而不是退化成宽泛的 `.pkla` 或 sudo。

规则示例（root:root 0644，放在 `/etc/polkit-1/rules.d/`）：

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

对应的 root oneshot unit：

```ini
[Unit]
Description=Apply a bas proxy bundle for %i
[Service]
Type=oneshot
ExecStart=/usr/local/libexec/basproxy-apply %i
```

`basproxy-apply` 只接受 `haproxy` / `nginx` 两个参数和 basagent 私有目录下的 bundle 路径；
路径必须属于 `bas`、非 symlink，且位于固定目录。验证时可用：

```bash
pkaction --action-id org.freedesktop.systemd1.manage-units --verbose
sudo -u bas systemctl start basproxy-apply@haproxy.service
journalctl -u basproxy-apply@haproxy.service
```

在 CentOS 7 上重点确认 polkit 版本（`rpm -q polkit`）和 `/etc/polkit-1/rules.d/` 是否被
polkitd 加载；不要在 CentOS 7 上额外安装宽泛的 `.pkla` 规则。

