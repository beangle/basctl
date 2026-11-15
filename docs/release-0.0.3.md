# Release 0.0.3

发布日期：待定

计划 tag：`v0.0.3`

本版本新增 `basctl proxy`：从 bashub 下载完整代理 ZIP，校验、安装并 reload。
代理节点不需要 `conf/server.xml`，也不安装常驻 service 或 timer。

## 版本范围

### `basctl proxy`

```bash
sudo basctl proxy apply --engine=haproxy
sudo basctl proxy apply --engine=nginx
sudo basctl proxy status --engine=haproxy
```

- 机器下载使用 `BAS_PRINCIPAL` / `BAS_TOKEN`。
- 不读取 `conf/server.xml`。
- `apply` 要求 root，写入代理配置、证书，执行配置检查和 reload。
- 失败时恢复旧文件，并删除本次新建的文件。

### 部署位置发现

配置位置按以下顺序确定：

1. `--config=FILE`
2. Nginx `nginx -V` 的 `--conf-path=`
3. systemd unit `ExecStart` 的 `-f` / `-c`
4. 常见默认路径

服务名默认等于引擎名，可用 `--service=NAME` 覆盖。

证书安装到配置文件所在目录的 `certs/`：

```text
/etc/haproxy/certs
/etc/nginx/certs
```

下载时通过 `cert-dir` 通知 bashub，因此 bundle 内配置引用同一路径。

### 本地应用

```bash
sudo basctl proxy apply --engine=haproxy --bundle=/tmp/proxy-bundle.zip
basctl proxy apply --engine=haproxy --bundle=/tmp/proxy-bundle.zip --dry-run
```

ZIP 内含 `manifest.json`、配置、证书和私钥；basctl 校验角色、路径和 SHA-256，
拒绝绝对路径和 `..`。

### 其他

- `start` 在删除实例目录前预检 jstart，缺失时给出明确错误。
- `vibe-stream` 依赖范围对齐 1.5。

## 升级

- 代理节点配置：

  ```bash
  set -a
  . /var/lib/bas/conf/basctl.env
  set +a
  sudo basctl proxy apply --engine=haproxy
  ```

- 不安装 `basctl-proxy.service` 或 timer；定时执行由外部调度负责。
- 不再使用 setline-agent 的 pull/render/apply。

## 验证

```text
dub build: 通过
dub test: 151 passed
```
