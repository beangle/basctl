# basctl proxy

`basctl proxy` **只应用本地 ZIP bundle**，不访问网络、不读取 `conf/server.xml`，也不理解代理拓扑。
bundle 由 bashub 渲染；需要远程更新时由 basagent 下载并通过 root helper 调用本命令，流程见
[basagent.md](basagent.md)。

## 命令

```bash
# 应用本地 bundle（root）
sudo basctl proxy apply --engine=haproxy --bundle=/tmp/proxy-bundle.zip
sudo basctl proxy apply --engine=nginx   --bundle=/tmp/proxy-bundle.zip

# 只检查当前落点
sudo basctl proxy status --engine=haproxy

# 只打印将写入的路径
basctl proxy apply --engine=haproxy --bundle=/tmp/proxy-bundle.zip --dry-run
```

`--bundle=FILE` 是 `apply` 的必填项。`--endpoint`、`--config`、`--service` 与以前一致。

## ZIP 内容

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

| 引擎 | 配置 | 证书 |
|---|---|---|
| haproxy | `config/haproxy.cfg`，路由在 `config/bas-routes.map` | 私钥和证书合并为 PEM |
| nginx | `config/nginx.conf` | 证书、私钥分文件 |

`manifest.json` 用 role 标注文件，并给出每个文件的 SHA-256；`basctl` 按 role 读取，不信任 ZIP 内的
绝对路径或 `..`。

## 应用流程

```text
读取 ZIP → manifest/schema/engine 校验 → 每个 role 的 SHA-256 校验
→ 写证书 → 写配置 → haproxy -c / nginx -t
→ systemctl reload（未运行时 start）
→ 失败恢复旧文件
```

失败不会留下半套配置；`--dry-run` 只打印目标路径，不写文件。该命令不安装 systemd service，
也不创建定时器。

## 部署位置

`basctl proxy` 按以下顺序发现代理配置：

1. `--config=FILE` 显式覆盖
2. Nginx `nginx -V` 的 `--conf-path=`
3. systemd unit `ExecStart` 的 `-f` / `-c`
4. 常见默认路径

服务名默认与引擎相同，可用 `--service=NAME` 覆盖。

## 远程触发

`basagent` 的 `proxy:apply` 会下载 bundle 并触发 `basproxy-apply@<engine>.service`；root helper
再调用本命令的 `--bundle` 形式。basagent 不写代理文件，sudoers 只授权两个固定 unit；详见
[basagent.md](basagent.md)。权限边界和 oneshot 执行链见
[proxy-oneshot.md](proxy-oneshot.md)。
