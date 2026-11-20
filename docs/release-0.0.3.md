# Release 0.0.3

发布日期：待定
计划 tag：`v0.0.3`

本版本把主机级凭证从 `$BAS_HOME/conf` 迁到 `/etc`，并增加 `proxy:apply`：bashub 可以经
basagent 触发代理 bundle 的校验、落盘和 reload；手工 `basctl proxy apply` 只接受本地
`--bundle`，不再下载。

## Breaking：`basctl.env` 迁到 `/etc`

`basctl.env` 现在是主机级配置，固定放在：

```text
/etc/bas/conf/basctl.env     root:beangle 0640
/etc/bas/conf/               root:beangle 0750
```

- systemd 只通过 `EnvironmentFile=-/etc/bas/conf/basctl.env` 注入；不再读取
  `/etc/sysconfig/basagent`、`/etc/default/basagent`。
- `bin/env.sh` 默认加载 `/etc/bas/conf/basctl.env`；源码/自定义目录用 `BAS_ENV_FILE` 指向自己的文件。
- `basctl init` 不再创建或修改 `basctl.env`，只铺控制脚本并建 `conf/`；缺少
  `BAS_PRINCIPAL`/`BAS_TOKEN` 时打印提示。
- `report:os` 增加 `proxy.haproxy` / `proxy.nginx` 版本（本机 `-v`），供监控页显示代理版本；
  未安装时为空串。
- 文档按职责拆分：basagent 的通道、配置投递、代理触发和排障集中到 `docs/basagent.md`，
  basctl 文档只保留本地 CLI。
- **不提供旧路径 fallback**：程序不读取 `/var/lib/bas/conf/basctl.env`。升级时需自行迁移：

  ```bash
  sudo install -d -m 0750 -o root -g beangle /etc/bas/conf
  sudo install -m 0640 -o root -g beangle \
    /var/lib/bas/conf/basctl.env /etc/bas/conf/basctl.env
  sudo systemctl restart basagent
  ```

- RPM/DEB 将模板装到 `/usr/share/bas/basctl.env`，`postinst`/`%post` 仅在
  `/etc/bas/conf/basctl.env` 缺失时创建；实际文件不由包管理跟踪，卸载/重装都不删除、不覆盖。
  旧 `/var/lib` 条目已移除。这样 `rpm -e` / `apt remove` / `apt purge` 都不会删掉主机凭证。

## 本机开机自启

`server.xml` 的 server 可声明：

```xml
<server name="app" http="8080">
  <auto-start>
    <wait-for ref="platform.db"/>
    <wait-for url="https://db.example/health" timeout="300"/>
    <wait-for tcp="db.example:5432" timeout="60"/>
  </auto-start>
</server>
```

- 只有带 `<auto-start>` 的本机 server 才由 `basctl autostart` 自动启动；
- `wait-for` 只允许作为 `auto-start` 的子元素；`ref` 是本机受管节点，`url/tcp` 是外部依赖；
- 本机 ref 形成 DAG，逐节点串行启动，不并发；
- basagent 有本地 `server.xml` 就调用 autostart；pull 失败但本地已有配置是正常离线场景；
- 没有 `server.xml` 不调用 autostart。

## 无 bas server 的 agent

`basagent pull` 会解析远端 `server.xml`；如果没有本机可运行的 bas server，就不安装该文件，
也不留下临时/空文件。`basagent.service` 不再要求 `server.xml` 存在。只跑 micdn 或代理的节点
仍然可以启动 agent、建立通道并执行 `micdn:reload` / `proxy:apply`。

## micdn 配置投递

`micdn:reload` 现在由 basagent 完成完整链路：

```text
GET /api/bashub/micdn/{project}/micdn.xml   (Bearer <Project.key>)
  → POST http://127.0.0.1:8888/admin/config
  → micdn 自己校验、原子写入 micdn.xml → reload
```

- basagent 不写 `/etc/micdn`，也不把 `BAS_TOKEN` 交给 micdn。
- micdn.xml 下载使用 Project key，不是 agent 握手用的 `<project>:<key>`。
- micdn 的 `/admin/config` 只接受 localhost，body 上限 4 MiB；失败时旧文件和旧 router 不变。
- micdn 不再读取 `BAS_PRINCIPAL`/`BAS_TOKEN`，`micdn.env` 已移除；启动必须有本地 `micdn.xml`。
- `/etc/micdn` 由 `micdn:beangle 0750` 所有，`micdn.xml` 为 `micdn:beangle 0640`。

## `proxy:apply`

新增 `proxy:apply` 控制通道原语：

```text
POST /api/bashub/config/projects/{id}/proxy/apply   (bashub 管理台)
  → basagent 下载 bundle 到 /var/lib/bas/proxy/<engine>.zip
  → sudo -n systemctl start basproxy-apply@<engine>.service
  → root helper 校验路径/属主/权限后执行
       basctl proxy apply --bundle=...
```

- 安装包新增 `/usr/libexec/basproxy-apply`、`basproxy-apply@.service` 和
  `/etc/sudoers.d/basproxy`。
- CentOS 7 的 systemd 219 不传 unit detail，polkit 无法限定 unit；sudoers 只放行 `bas` 对
  `basproxy-apply@haproxy.service` / `@nginx.service` 的 `systemctl start`；basagent 关闭
  `NoNewPrivileges` 以允许 sudo 提升。
- helper 只接受 `haproxy` / `nginx` 两个模板实例参数，不联网、不读取 `BAS_TOKEN`；bundle 路径固定，
  必须属于 `bas`、权限 0600、非 symlink；用 `flock` 串行化同一引擎的 apply。
- root helper 复用现有 `basctl proxy apply`：manifest/hash 校验、`haproxy -c` / `nginx -t`、
  原子替换、失败回滚全部保留。
- 缺少 helper、sudoers 未授权或 unit 启动失败时**失败关闭**，不会放开为任意 systemctl。

## 修复

- `server.xml` 只有实际出现 `${bas_remote_url}` / `${bas_remote_token}` 时才读取
  `BAS_PRINCIPAL`/`BAS_TOKEN`；本地配置不会因残留的远端环境变量解析失败。
- `loadRemoteEnv` 增加显式参数重载，远程配置测试不再修改进程环境。

## 升级

1. 按上面的命令迁移 `/etc/bas/conf/basctl.env`，确认属主/权限后重启 `basagent`。
2. 代理节点安装新版 basctl/basagent 后，确认 `basproxy-apply@.service`、
   `/usr/libexec/basproxy-apply` 和 `/etc/sudoers.d/basproxy` 已就位；用 `visudo -cf`/`journalctl` 验证。
3. bashub 端升级到 **0.0.9** 及以上，支持 `proxy:apply`、`micdn:reload` 和 server.xml 的
   `<auto-start>` / `<wait-for>`；管理台按 Project 的 endpoint `ips` 触发。
4. `basctl init` 不再生成 env；源码安装请显式设置 `BAS_ENV_FILE`。

## 验证

```text
dub build -c basagent: 通过
dub build -c basctl: 通过
dub test: 153 passed
RPM 构建: 通过（/usr/share/bas/basctl.env、/usr/libexec/basproxy-apply、
basproxy-apply@.service、/etc/sudoers.d/basproxy 均在包内）
DEB 构建: 本环境未执行
```
