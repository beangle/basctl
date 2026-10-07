/* Copyright (C) 2023 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

/**
 * `basctl doctor`：检查 basctl 会用到的外部命令与入口是否就位。
 *
 * basctl 自己不起进程池，也不直接 exec java，而是把命令交给别的程序：
 *
 *  - `java`：`make`（creator 与只准备）写出的启动命令、以及 jstart 最终 exec 的都是 java，
 *    按 `JAVA_HOME/bin/java` > `PATH` 解析（与 creator 里 `javaExecutable` 同一顺序）；
 *  - `jstart`：`start` / `make` / `resolve` 用它解析下载构件，命令名可用 `beangle_jstart` 覆盖；
 *  - `setline`：只有 `server.xml` 里声明了 `<setline>` 才检查，而且检的是**入口可达**而不是命令
 *    存在——setline 是机器级服务（systemd / 容器入口 / 手工拉起），basctl 只往它的写接口推
 *    路由，不调用它的可执行文件。入口地址取自 `<setline endpoint>`（缺省 `127.0.0.1:8080`），
 *    与 `--sync` / `start` / `status` 走同一个解析入口。
 *
 * 只检查“就位没就位”，**不校验版本**：java / jstart / setline / 容器的版本策略分别属于各自的
 * 发布节奏，basctl 掺和只会制造漂移。缺件时打印安装提示，并让退出码非 0。
 *
 * 打包（deb/rpm）不声明对这些命令的硬依赖：安装方式太多（系统包、sdkman、手工放置），
 * 硬依赖会挡住“先装 basctl、再按需补命令”的用法；缺件交给本命令在运行时提示。
 */
module bas.doctor;

import bas.config : parseServerXmlFile;
import bas.jstart : jstartEnvVar;
import bas.endpoint : SetlineEndpointChoice, portFree, resolveSetlineEndpoint, sourceName;

import std.array : join, split;
import std.conv : to;
import std.file : exists, isFile;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.stdio : writeln;
import std.string : indexOf, leftJustify, strip;

/** 一条检查的结论。 */
enum CheckState {
  /** 找到且可用。 */
  ok,
  /** 必需但没找到。 */
  missing,
  /** 当前配置下用不到，不判定。 */
  skipped
}

/** 一条命令的检查结果。 */
struct ToolCheck {
  string name;
  CheckState state;
  /** 找到时的绝对路径（`ok` 才有值）。 */
  string path;
  /** 解析来源：`JAVA_HOME` / `PATH` / `beangle_jstart` / `server.xml` / `default`。 */
  string source;
  /** `missing` / `skipped` 的一句话说明。 */
  string note;

  /** 展示状态：`ok` / `MISSING` / `skip`。 */
  string status() const {
    final switch (state) {
    case CheckState.ok:
      return "ok";
    case CheckState.missing:
      return "MISSING";
    case CheckState.skipped:
      return "skip";
    }
  }
}

/**
 * 解析命令时要用到的环境。默认取自进程环境（{@link ToolEnv.fromProcess}）；也允许显式构造，
 * 好让本模块的检查保持纯函数——测试并行跑时不必去改进程级环境变量这种共享状态。
 */
struct ToolEnv {
  /** `JAVA_HOME`；空串表示没设，退回 `PATH`。 */
  string javaHome;
  /** `PATH`，按平台分隔符拆分。 */
  string path;
  /** {@link jstartEnvVar} 的值；空串表示按 `PATH` 找 `jstart`。 */
  string jstart;

  /** 取当前进程环境（`basctl doctor` 走这条）。 */
  static ToolEnv fromProcess() {
    return ToolEnv(strip(environment.get("JAVA_HOME", "")), environment.get("PATH", ""),
        strip(environment.get(jstartEnvVar, "")));
  }
}

/**
 * 检查 basctl 需要的命令；`confFile` 只用于判断 setline 是否必需
 * （文件缺失或解析失败都按“未启用 setline”处理，不因此报错）。
 */
ToolCheck[] checkTools(string confFile) {
  return checkTools(confFile, ToolEnv.fromProcess());
}

/// ditto
ToolCheck[] checkTools(string confFile, in ToolEnv env) {
  ToolCheck[] checks;
  checks ~= checkJava(env);
  checks ~= checkJstart(env);
  auto setline = setlineConfigState(confFile);
  checks ~= checkSetline(setline);
  return checks;
}

/** `<setline>` 的启用状态、配置里写的入口地址（可能为空）与展示用说明。 */
private struct SetlineConfigState {
  bool enabled;
  string endpoint;
  string note;
}

/**
 * `server.xml` 是否启用了 setline：只有 `<setline>` 出现才算（与 config.d 的“出现即启用”一致）。
 * 文件不存在或解析失败时按未启用处理，说明写进 `note`。
 */
private SetlineConfigState setlineConfigState(string confFile) {
  if (!exists(confFile))
    return SetlineConfigState(false, "", "no config file " ~ confFile);
  try {
    auto conf = parseServerXmlFile(confFile);
    if (conf.setlineHostname.isNull)
      return SetlineConfigState(false, "", "no <setline> in " ~ confFile);
    return SetlineConfigState(true, conf.setlineEndpointText(), "<setline hostname=\""
        ~ strip(conf.setlineHostname.get) ~ "\">");
  } catch (Exception e) {
    return SetlineConfigState(false, "", "cannot parse " ~ confFile);
  }
}

/** java：`JAVA_HOME/bin/java` 优先，其次 `PATH`。 */
private ToolCheck checkJava(in ToolEnv env) {
  version (Windows)
    enum exe = "java.exe";
  else
    enum exe = "java";

  auto home = env.javaHome;
  if (home.length) {
    auto bin = buildPath(home, "bin", exe);
    if (isRegularFile(bin))
      return available("java", absolutePath(bin), "JAVA_HOME");
  }
  auto found = findOnPath(exe, env.path);
  if (found.length)
    return available("java", found, "PATH");
  auto why = home.length ? "JAVA_HOME/bin/" ~ exe ~ " does not exist" : "not on PATH";
  return unavailable("java", "install a JDK (" ~ why ~ "), or set JAVA_HOME");
}

/** jstart：`beangle_jstart` 指向的命令 > `PATH` 上的 `jstart`。 */
private ToolCheck checkJstart(in ToolEnv env) {
  auto source = env.jstart.length ? jstartEnvVar : "PATH";
  auto found = resolveCommand(env.jstart.length ? env.jstart : "jstart", env.path);
  if (found.length)
    return available("jstart", found, source);
  return unavailable("jstart", source == jstartEnvVar
      ? jstartEnvVar ~ " points to " ~ env.jstart ~ ", but that command was not found"
      : "install jstart, or set " ~ jstartEnvVar ~ " to its path");
}

/**
 * setline：只有 `<setline>` 配置时才检查——检的是**入口可达**（有人在监听），而不是命令存在：
 * setline 归 systemd / 容器入口 / 手工起，basctl 只往它的写接口推路由。
 *
 * 入口地址走与 `setline --sync` / `start` / `status` 同一个解析入口，`source` 报它的出处
 * （`server.xml` 或 `default`），不必再去猜环境里设了什么。
 */
private ToolCheck checkSetline(SetlineConfigState setline) {
  if (!setline.enabled)
    return ToolCheck("setline", CheckState.skipped, "", "", "not required: " ~ setline.note);
  auto configNote = setline.note;
  if (setline.endpoint.length)
    configNote ~= " endpoint=" ~ setline.endpoint;

  SetlineEndpointChoice choice;
  try
    choice = resolveSetlineEndpoint("", setline.endpoint);
  catch (Exception e)
    return unavailable("setline", e.msg ~ " (" ~ configNote ~ ")");
  if (portFree(choice.endpoint))
    return unavailable("setline", "nothing listens on " ~ choice.endpoint.toString()
        ~ "; start the setline service, or point <setline endpoint=\"...\"> at it ("
        ~ configNote ~ ")");
  return ToolCheck("setline", CheckState.ok, choice.endpoint.toString(),
      sourceName(choice.source), "");
}

/** 组装一条“找到”的结果。 */
private ToolCheck available(string name, string path, string source) {
  return ToolCheck(name, CheckState.ok, absolutePath(path), source, "");
}

/** 组装一条“缺失”的结果。 */
private ToolCheck unavailable(string name, string note) {
  return ToolCheck(name, CheckState.missing, "", "", note);
}

/**
 * 按 `PATH` 查找命令（Windows 追加 `PATHEXT`），找不到返回空串。与 jstart 同一约定：
 * 只要求“是文件”，不检查 POSIX 可执行位（Windows 上本来就没有）。
 */
string findOnPath(string name, string path) {
  version (Windows) {
    immutable string[] exts = environment.get("PATHEXT", ".COM;.EXE;.BAT;.CMD").split(";");
    immutable sep = ';';
  } else {
    immutable string[] exts = [""];
    immutable sep = ':';
  }
  foreach (dir; path.split(sep)) {
    if (dir.length == 0)
      continue;
    foreach (ext; exts) {
      auto candidate = buildPath(dir, name ~ ext);
      if (isRegularFile(candidate))
        return candidate;
    }
  }
  return "";
}

/**
 * 是存在的普通文件。`exists`（lstat）与 `isFile`（再 lstat 一次）之间文件可能被删，而 `isFile`
 * 对缺失文件会抛 `FileException`；扫 `PATH` 不该因为某个候选在扫描途中消失就整体报错，吞掉即可。
 */
private bool isRegularFile(string path) @trusted {
  try
    return exists(path) && isFile(path);
  catch (Exception)
    return false;
}

/** 解析一个“命令或路径”：含分隔符按路径（存在才用），否则查 `PATH`。 */
private string resolveCommand(string value, string path) {
  auto cmd = strip(value);
  if (cmd.length == 0)
    return "";
  if (cmd.indexOf('/') >= 0 || cmd.indexOf('\\') >= 0) {
    if (isRegularFile(cmd))
      return absolutePath(cmd);
    return "";
  }
  auto found = findOnPath(cmd, path);
  return found.length ? absolutePath(found) : "";
}

/**
 * 渲染检查结果：每个命令一行（名称左对齐 + 状态 + 路径/说明），最后一行是总结。
 * 调用方只管打印与退出码，格式集中在这里，方便测试。
 */
string renderChecks(string confFile, const(ToolCheck)[] checks) {
  size_t width = "config".length;
  foreach (check; checks) {
    if (check.name.length > width)
      width = check.name.length;
  }
  string[] lines;
  auto state = setlineConfigState(confFile);
  auto configNote = exists(confFile) ? " (" ~ state.note ~ ")" : " (not found)";
  lines ~= leftJustify("config", width) ~ "  " ~ confFile ~ configNote;
  foreach (check; checks) {
    auto detail = check.state == CheckState.ok
        ? check.path ~ " (" ~ check.source ~ ")"
        : check.note;
    lines ~= leftJustify(check.name, width) ~ "  " ~ leftJustify(check.status(), 7) ~ " " ~ detail;
  }
  size_t missing;
  foreach (check; checks) {
    if (check.state == CheckState.missing)
      missing++;
  }
  lines ~= (missing
      ? "doctor: " ~ missing.to!string ~ " required command(s) missing."
      : "doctor: all required commands are available.");
  return lines.join("\n");
}

/** `basctl doctor`：[`runDoctor`] 的 CLI 壳：打印检查结果，缺件时返回 1。 */
int runDoctor(string confFile) {
  auto checks = checkTools(confFile);
  writeln(renderChecks(confFile, checks));
  foreach (check; checks) {
    if (check.state == CheckState.missing)
      return 1;
  }
  return 0;
}
