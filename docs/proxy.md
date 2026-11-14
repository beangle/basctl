# basctl proxy

`basctl proxy` 从 bashub 下载完整的代理配置 ZIP，校验后安装到本机并 reload。

它不读取 `conf/server.xml`，也不理解路由拓扑；代理配置完全由 bashub 生成。

## 下载

```bash
sudo basctl proxy apply --engine=haproxy
sudo basctl proxy apply --engine=nginx
```

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
| haproxy | `config/haproxy.cfg`，HAProxy 语法 | basctl 将私钥和证书合并为 PEM |
| nginx | `config/nginx.conf`，Nginx 语法 | 证书、私钥分文件安装 |

Micdn 路由也会写入同一份配置：

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

## 安装位置

```text
haproxy:
  /etc/haproxy/haproxy.cfg
  /etc/basproxy/certs/<endpoint>.bundle.pem

nginx:
  /etc/nginx/nginx.conf
  /etc/basproxy/certs/<endpoint>.pem
  /etc/basproxy/certs/<endpoint>.key.pem
```

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

只有在以下情况才考虑 map：

- 路由数量达到数千条
- 需要不 reload 动态更新路由
- 多个 Project 共享同一个 HAProxy 实例

当前方案保持 ACL，避免为少量路由引入 map 文件和状态同步。
