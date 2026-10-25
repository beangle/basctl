# native engine

`engine type="native"` 用于启动 GraalVM native-image 等 `tar.gz` 可执行包，不启动 Tomcat/JVM 容器。

## server.xml

```xml
<native-repo remote="${bas_remote_url}/native" token="..."/>

<engines>
  <engine name="native" type="native" version="1"/>
</engines>

<farms>
  <farm name="portal" engine="native">
    <server name="app1" http="8080"/>
  </farm>
</farms>

<webapps>
  <webapp
    uri="gav://org.beangle.ems:beangle-ems-portal:tar.gz:linux-amd64:4.20.15-SNAPSHOT"
    path="/"
    run-at="portal.app1"/>
</webapps>
```

- 一个 native server 只允许一个 webapp
- `exec` 可选；缺省为 artifactId
- `native-repo` 的地址作为 jstart 的 `--remote`，不传 `--snapshot-remote`

## 启动

`basctl start` 删除 `servers/<server>` 后写入：

```ini
[app]
entry = gav://...:tar.gz:linux-amd64:...
base = /var/lib/bas/servers
instance = portal.app1
working_dir = /var/lib/bas

[engine]
init = /usr/bin/basctl make native --name=beangle-ems-portal

[args]
--port=8080
--path=/
```

jstart 取包后执行 `basctl make native`：

1. 解压 tar.gz 到 `servers/<server>`
2. 如果压缩包只有一个顶层目录，自动剥离该目录
3. 按 `exec`、`<artifactId>`、`bin/<artifactId>`、唯一可执行文件的顺序定位
4. 写 `jstart.argv`

## 目录

```text
servers/<server>/
  <native files>
  launch.jstart
  server.info
  jstart.argv
  logs -> ...
```

没有 Tomcat 的 `bin/conf/lib/webapps/work/temp`，除非 native 包自己带这些文件。

## 正式版 / SNAPSHOT

- 正式版：按版本号缓存
- SNAPSHOT：jstart 在本地命中前比对远端 `.sha1`，同名包更新时重新下载
- native 仓库单根，正式版和 SNAPSHOT 按版本目录区分
