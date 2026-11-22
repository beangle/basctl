# Release 0.0.4

发布日期：待定
计划 tag：`v0.0.4`

本版本补齐 micdn 配置安装、服务状态上报和启动就绪判定。

## micdn 配置安装

`micdn:reload` 不再 POST `/admin/config`：

```text
basagent 下载 micdn.xml 到 /var/lib/bas/micdn/micdn.xml
  → sudo -n systemctl start basmicdn-apply.service
  → root helper: micdn --check
  → 备份、原子安装 /etc/micdn/micdn.xml
  → systemctl restart micdn
  → 失败恢复旧配置
```

micdn 停止时也能应用，不再依赖管理端口。

## 服务状态上报

`report:os` / `report:health` 增加：

- `micdn: {active, state}`
- `proxyState: {haproxy: {active, state}, nginx: {active, state}}`

监控页按实际 `systemctl is-active` 显示在线、已停止、节点离线或状态未知。

## 启动就绪

`basctl start` / `service:start` 等待进程存活且 HTTP 端口实际 LISTEN（最多 30 秒）；
进程提前退出或端口未监听时删除 `server.info` 并返回失败。

## 清理已删除部署

远端 `server.xml` 不再包含本机 bas server 时，basagent 删除旧 `server.xml`；
proxy/micdn-only agent 仍可无配置运行。

## 升级

1. 安装新 basctl/basagent RPM/DEB；
2. `systemctl daemon-reload && systemctl restart basagent`；
3. 确认 `/etc/sudoers.d/basproxy` 包含 `basmicdn-apply.service` 和两个 proxy unit；
4. micdn 侧需 0.4.3 的 `micdn --check`（如果先升级 basctl，配置 apply 会失败）。

## 验证

```text
dub test：153 passed
RPM 构建：通过
DEB 构建：本环境未执行
```
