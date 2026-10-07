# basctl roadmap

本文件跟踪 basctl 自身的后续功能。与 setline 的集成设想（动态端口、自动注册、对账、
容器化等）另见 [setline-roadmap.md](setline-roadmap.md)。

## 环境自检（`basctl doctor`）

**状态：已落地**（见 [doctor.md](doctor.md)）。

**目标**：一条命令检查 basctl 运行所依赖的外部命令是否就位——`java`、`jstart`、`setline`。
先只检查"命令存在且可执行"，**暂不校验版本**（避免与 engine / 应用的版本策略耦合）。

- `java`：`start` / `run` 都要（jstart 侧 exec java），按 `$JAVA_HOME/bin/java` 或 `PATH` 解析；
- `jstart`：`start` 用（可用 `beangle_jstart` 覆盖路径）；
- `setline`：只在启用 setline（`server.xml` 配了 `<setline>`）时才必需；
- 逐项报告解析出的路径与结论；缺件时给出安装提示并让退出码非 0；
- ~~可选接线：`start` 前先跑一遍~~：**不做**。`start` 缺件时 jstart 已经给出明确报错，
  再加一个「先 doctor、缺件拒绝启动」的开关只多一个旋钮而没有新信息；doctor 保持独立命令。

**打包**：deb/rpm **不强行依赖**这些命令——`java`/`jstart`/`setline` 的安装方式（系统包、
`sdkman`、手工放置）太多，硬依赖会挡住"先装 basctl、再按需补命令"的用法。最多写
`Recommends` / `Suggests`，缺件交由自检在运行时提示。

**验收**

- [x] `basctl doctor` 输出 java / jstart / setline 的路径与状态，缺件时退出码非 0
- [x] 未启用 setline 时不把 setline 记为缺失
- [x] deb/rpm 不声明对 java / jstart / setline 的硬依赖（只依赖 `curl`）
