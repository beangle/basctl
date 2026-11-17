# Release 0.0.2

发布日期：2026-11-17  
Tag：`v0.0.2`

本版本新增 `basctl proxy`，并完成远程凭证、配置模板、jstart 预检和依赖调整。
代理节点不再部署常驻 service 或 timer。

## 版本范围

### `basctl proxy`

```bash
sudo basctl proxy apply --engine=haproxy
sudo basctl proxy apply --engine=nginx
basctl proxy status --engine=haproxy
```

- 机器下载使用 `BAS_PRINCIPAL` / `BAS_TOKEN`。
- 不读取 `conf/server.xml`。
- `apply` 要求 root，写入代理配置、路由 map、证书，执行配置检查和 reload/start。
- 失败时恢复旧文件，并删除本次新建的文件。
- HAProxy 使用 `config/bas-routes.map`；Nginx 继续使用 location。

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

下载时通过 `cert-dir` / `route-map` 通知 bashub，因此 bundle 内配置引用同一路径。

### 本地应用

```bash
sudo basctl proxy apply --engine=haproxy --bundle=/tmp/proxy-bundle.zip
basctl proxy apply --engine=haproxy --bundle=/tmp/proxy-bundle.zip --dry-run
```

ZIP 内含 `manifest.json`、配置、证书和私钥；HAProxy 还包含 `bas-routes.map`。
basctl 校验角色、路径和 SHA-256，拒绝绝对路径和 `..`。

### 远程凭证与配置

- 删除 `basctl.conf` 的 `[remote]` 段，改用：

  ```bash
  BAS_PRINCIPAL=project@url
  BAS_TOKEN=...
  ```

- `pull` 不再接受 `--file`；启动拉取失败即失败，不做本地兜底。
- 安装包下发 `basctl.env`，systemd 通过 `EnvironmentFile` 读取。
- `basagent` 只从环境变量读取 Project 和 token。

### 其他

- `start` 在删除实例目录前预检 jstart，缺失时给出明确错误。
- `vibe-stream` 依赖范围对齐 1.5。
- `proxy apply` 在服务 inactive 时启动，运行中才 reload。

## 升级

- 代理节点配置：

  ```bash
  set -a
  . /var/lib/bas/conf/basctl.env
  set +a
  sudo basctl proxy apply --engine=haproxy
  ```


## 验证

```text
dub build: 通过
dub test: 151 passed
```
