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
 * `basctl start`：按 farm 生成 jstart 启动 spec 并拉起实例。
 *
 * 沿用 sas「按 farm 启动」的语义，启动本身交给 jstart：
 *
 *  1. 从 `conf/server.xml` 选出匹配的本机 `<Server>`（farm 名 / `farm.server` / `all`）；
 *  2. 逐个解析 webapp（沿用 `make`/`resolve` 的语义），为每个 `<Server>` 生成一份
 *     launch spec `conf/<farm.server>.jstart`——一个 `<Server>` 一个 JVM，内部每个
 *     webapp 一段 `[subapp <id>]`（各自 docBase 与 `libs`，依赖互不串味）；
 *  3. `jstart resolve <spec>` 校验 spec 与依赖齐备；
 *  4. 后台 `jstart run <spec>`：jstart 先运行 `[engine] init` 脚本（本命令生成的
 *     wrapper）→ `basctl engine tomcat-dist` 准备容器环境并写出最终启动命令，
 *     jstart 再 exec 它。
 *
 * 实例目录沿用 `servers/<farm.server>`——spec 里写 `[app] base = $SAS_HOME/servers`
 * 加 `[app] instance = <farm.server>`，jstart 的直接组件目录就是它；`SERVER_PID` 与
 * `logs/console.out` 也与既有 `status`/`make` 的布局一致。
 */
module bas.starter;

import bas.artifact : gavProtocol, isGav, isRemote, parseArtifact, toArtifact;
import bas.config;
import bas.fsutil : linkIfMissing, setExecutable;
import bas.jstart : fetch, jstartCommand;
import bas.net : localAddresses;
import bas.resolver : resolveArtifact, resolveWebapps;
import bas.serverstatus : processRunning, rollLog;
import bas.tomcatmaker : applyEngineDefault;

import core.thread : Thread;
import core.time : msecs;

import std.algorithm : canFind;
import std.array : appender, join, split;
import std.conv : to;
import std.file : exists, mkdirRecurse, read, readLink, readText, remove, write;
import std.format : format;
import std.path : absolutePath, buildPath, dirName;
import std.process : Config, environment, execute;
import std.stdio : stderr, writeln;
import std.string : replace, startsWith, strip;
import std.typecons : Nullable, nullable;
import std.zip : ZipArchive;

/** 启动后等待多久（毫秒）再确认进程存活，用于 Webapp 启动失败/依赖缺失的快速反馈。 */
private enum startupProbeMs = 2000;

/**
 * `basctl start [server.xml] <farm|server|all>`：生成 spec、resolve，然后后台启动。
 *
 * 任一实例准备失败只跳过该实例（写 `servers/<name>/error`），其余照常启动。
 */
int runStart(string configFile, string pattern) {
  if (!exists(configFile)) {
    stderr.writeln("Cannot find config file " ~ configFile);
    return 1;
  }
  auto container = parseServerXmlFile(configFile);
  auto sasHome = dirName(dirName(absolutePath(configFile)));
  auto ips = localAddresses();

  Server[] servers;
  foreach (farm; container.farms) {
    foreach (server; farm.servers) {
      if (!ips.canFind(server.host.ip))
        continue;
      if (pattern == "all" || pattern == farm.name || pattern == server.qualifiedName)
        servers ~= server;
    }
  }
  if (!servers.length) {
    stderr.writeln("No local server matches " ~ pattern);
    return 1;
  }

  // 补齐 sas 对 tomcat 的默认要求（Loader/JarScanner/引擎 jar），每个引擎只补一次
  Engine[] engines;
  foreach (farm; container.farms)
    foreach (server; farm.servers)
      if (servers.canFind(server) && !engines.canFind(farm.engine))
        engines ~= farm.engine;
  foreach (engine; engines)
    applyEngineDefault(container, engine);

  // 1. 先准备（生成 spec + resolve），失败不启动；这样多个实例不会半启动
  PreparedServer[] prepared;
  int alreadyRunning;
  foreach (server; servers) {
    auto pid = runningPid(sasHome, server);
    if (!pid.isNull) {
      writeln(server.qualifiedName ~ " appears to still be running with PID " ~ pid.get.to!string
          ~ ". Start skipped.");
      alreadyRunning++;
      continue;
    }
    auto spec = prepareServer(sasHome, container, server);
    if (!spec.isNull)
      prepared ~= PreparedServer(server, spec.get);
  }
  if (!prepared.length) {
    // 目标都已在运行（幂等重入）：视为成功；否则是准备失败
    if (alreadyRunning == servers.length)
      return 0;
    stderr.writeln("No instance was prepared; nothing started.");
    return 1;
  }

  // 2. 后台启动，再统一确认存活
  int[] pids;
  foreach (ref p; prepared) {
    prepareLog(sasHome, p.server);
    pids ~= launchBackground(p.spec, consoleLog(sasHome, p.server));
  }

  Thread.sleep(msecs(startupProbeMs));

  int started;
  foreach (i, ref p; prepared) {
    if (pids[i] > 0 && processRunning(pids[i])) {
      writePidFile(sasHome, p.server, pids[i]);
      writeln(format!"%s started (pid=%s, log=%s)"(p.server.qualifiedName, pids[i],
          consoleLog(sasHome, p.server)));
      started++;
    } else {
      stderr.writeln(p.server.qualifiedName ~ " failed to start, see " ~ consoleLog(sasHome, p.server));
      printLogTail(consoleLog(sasHome, p.server));
    }
  }
  writeln(started, " servers started.");
  return started == prepared.length ? 0 : 1;
}

/** 一个已备好 spec 的实例。 */
private struct PreparedServer {
  Server server;
  string spec;
}

/**
 * 为单个 `<Server>` 生成 spec：解析 webapp、确保引擎依赖本地齐备、写出入口 wrapper
 * 与 `conf/<name>.jstart`。成功返回 spec 路径，失败返回空。
 */
private Nullable!string prepareServer(string sasHome, Container container, Server server) {
  auto webapps = container.getWebapps(server);
  if (!webapps.length) {
    writeln(server.qualifiedName ~ ": no webapp deployed, skipped.");
    return Nullable!string.init;
  }

  auto engine = server.farm.engine;
  if (engine.typ != engineTomcat) {
    stderr.writeln(server.qualifiedName ~ ": engine type " ~ engine.typ
        ~ " is not supported by start (use a tomcat farm)");
    return Nullable!string.init;
  }

  auto serverDir = buildPath(sasHome, "servers", server.qualifiedName);
  auto errorFile = buildPath(serverDir, "error");
  auto missings = resolveWebapps(sasHome, container.repository, container.snapshotRepo, webapps);
  mkdirRecurse(serverDir);
  if (missings.length) {
    write(errorFile, missings.join("\n"));
    stderr.writeln("Cannot resolve " ~ server.qualifiedName ~ ", see details: " ~ errorFile);
    return Nullable!string.init;
  }
  if (exists(errorFile))
    remove(errorFile);

  string[] engineDeps;
  if (!collectEngineDeps(container, engine, container.repository, container.snapshotRepo, engineDeps))
    return Nullable!string.init;

  auto initScript = writeInitWrapper(sasHome, engine.typ);
  auto spec = buildPath(sasHome, "conf", server.qualifiedName ~ ".jstart");
  mkdirRecurse(dirName(spec));
  write(spec, renderLaunchSpec(buildPath(sasHome, "servers"), server.qualifiedName, sasHome,
      initScript, engineDeps, runtimeArgsFor(server), appArgsFor(server), subappSpecs(webapps)));
  writeln(server.qualifiedName ~ ": wrote " ~ spec);
  if (!resolveSpec(spec))
    return Nullable!string.init;
  return nullable(spec);
}

/** 一个 `[subapp <id>]` 段：webapp 的本地入口、上下文路径与扩展依赖。 */
struct SubappSpec {
  string id;
  string entry;
  string path;
  string libs;
}

/** 把 server 的 webapp 列表转成 spec 的 `[subapp]` 段（id 由 context path 推导并去重）。 */
SubappSpec[] subappSpecs(Webapp[] webapps) {
  SubappSpec[] specs;
  string[] used;
  foreach (app; webapps) {
    auto id = subappId(app.contextPath, used);
    used ~= id;
    auto libs = app.libs.isNull ? "" : strip(app.libs.get);
    specs ~= SubappSpec(id, app.docBase, app.contextPath, libs);
  }
  return specs;
}

/** subapp 段头 id：由 context path 推导（非 `[A-Za-z0-9._-]` 换成 `-`），必要时加序号。 */
string subappId(string contextPath, const(string)[] used) {
  string id;
  foreach (c; strip(contextPath)) {
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
        || c == '.' || c == '_' || c == '-')
      id ~= c;
    else
      id ~= '-';
  }
  while (id.length && id[0] == '-')
    id = id[1 .. $];
  while (id.length && id[$ - 1] == '-')
    id = id[0 .. $ - 1];
  if (id.length == 0)
    id = "ROOT";
  auto base = id;
  for (int n = 2; used.canFind(id); n++)
    id = base ~ "-" ~ n.to!string;
  return id;
}

/**
 * 渲染 jstart launch spec：`[app] base` 是 base 根（`$SAS_HOME/servers`），
 * `[app] instance = <farm.server>` 让 jstart 把组件目录直接定为 `servers/<farm.server>`；
 * `[engine] init` 是本命令生成的 wrapper，每个 webapp 一段 `[subapp <id>]`。依赖（引擎/容器
 * jar）与 JVM 参数分别写进 `[engine]` 与 `[runtime]`，端口等透传参数进 `[args]`。
 */
string renderLaunchSpec(string baseRoot, string instance, string workingDir, string initScript,
    const(string)[] engineDeps, const(string)[] runtimeArgs, const(string)[] appArgs,
    const(SubappSpec)[] subapps) {
  auto sb = appender!string;
  sb.put("# Generated by basctl start. Do not edit.\n\n");
  sb.put("[app]\n");
  sb.put("base = " ~ baseRoot ~ "\n");
  if (instance.length)
    sb.put("instance = " ~ instance ~ "\n");
  if (workingDir.length)
    sb.put("working_dir = " ~ workingDir ~ "\n");
  sb.put("\n[engine]\n");
  sb.put("init = " ~ initScript ~ "\n");
  foreach (dep; engineDeps)
    sb.put(dep ~ "\n");
  if (runtimeArgs.length) {
    sb.put("\n[runtime]\n");
    foreach (arg; runtimeArgs)
      sb.put(arg ~ "\n");
  }
  if (appArgs.length) {
    sb.put("\n[args]\n");
    foreach (arg; appArgs)
      sb.put(arg ~ "\n");
  }
  foreach (app; subapps) {
    sb.put("\n[subapp " ~ app.id ~ "]\n");
    sb.put("entry = " ~ app.entry ~ "\n");
    sb.put("path = " ~ (app.path.length ? app.path : "/") ~ "\n");
    if (app.libs.length)
      sb.put("libs = " ~ app.libs ~ "\n");
  }
  return sb.data;
}

/** `[runtime]`：sas 的 JVM 默认参数 + `<Farm><ServerOptions>`。 */
string[] runtimeArgsFor(Server server) {
  auto farm = server.farm;
  auto heap = server.maxHeapSize.length ? server.maxHeapSize : "300M";
  string[] args = ["-server", "-Djava.awt.headless=true", "-Xmx" ~ heap,
    "-Djava.security.egd=file:/dev/./urandom", "-Dsas.server=" ~ server.qualifiedName];
  if (!farm.serverOptions.isNull) {
    foreach (line; farm.serverOptions.get.split("\n")) {
      auto one = strip(line);
      if (one.length)
        args ~= one;
    }
  }
  return args;
}

/** `[args]`：透传给引擎入口的参数（端口、JSP 开关）。 */
string[] appArgsFor(Server server) {
  string[] args;
  if (server.http > 0)
    args ~= "--port=" ~ server.http.to!string;
  if (server.farm.engine.jspSupport)
    args ~= "--jsp=true";
  return args;
}

/**
 * `[engine]` 依赖行：tomcat 发行包 + `<Engine><Jar>`（`applyEngineDefault` 已把引擎 jar
 * 加进去）+ 引擎 jar 随包发布的 `META-INF/beangle/dependencies`（引擎运行时依赖）。
 *
 * 逐条校验确保本地齐备（gav 走 jstart fetch），缺失即失败——避免 `run` 阶段才发现。
 */
bool collectEngineDeps(Container container, Engine engine, Repository repo,
    SnapshotRepo snapshotRepo, ref string[] deps) {
  deps ~= "org.apache.tomcat:tomcat:zip:" ~ engine.version_;
  foreach (jar; engine.jars) {
    string dep;
    if (isGav(jar.uri))
      dep = toArtifact(jar.uri).asGav();
    else if (isRemote(jar.uri))
      dep = jar.uri;
    else
      dep = absolutePath(jar.uri);
    if (!deps.canFind(dep))
      deps ~= dep;
  }

  auto engineGav = "org.beangle.sas:beangle-sas-engine:" ~ container.version_;
  auto engineJar = fetch(engineGav, repo);
  if (engineJar.isNull) {
    stderr.writeln("Cannot fetch " ~ engineGav);
    return false;
  }
  foreach (line; readZipEntry(engineJar.get, "META-INF/beangle/dependencies").split("\n")) {
    auto dep = strip(line);
    if (dep.length && !deps.canFind(dep))
      deps ~= dep;
  }

  foreach (dep; deps) {
    if (!looksLikeGav(dep))
      continue;
    auto artifact = dep.startsWith(gavProtocol) ? toArtifact(dep) : parseArtifact(dep);
    if (resolveArtifact(repo, snapshotRepo, artifact).isNull) {
      stderr.writeln("Cannot resolve engine dependency " ~ dep);
      return false;
    }
  }
  return true;
}

/** 一行是 maven 坐标（而不是本地路径 / http url）。 */
private bool looksLikeGav(string line) {
  if (isGav(line))
    return true;
  if (isRemote(line))
    return false;
  if (line.startsWith("~") || line.startsWith("/") || line.startsWith("."))
    return false;
  return line.split(":").length >= 3;
}

/** 读取 jar/zip 内某个条目为文本；缺失或读不了时返回空串。 */
string readZipEntry(string zipPath, string entry) {
  try {
    auto zip = new ZipArchive(cast(ubyte[]) read(zipPath));
    if (auto member = entry in zip.directory)
      return cast(string) zip.expand(*member);
  } catch (Exception) {
    // 忽略：读不了就当没有清单
  }
  return "";
}

/**
 * 写出（或刷新）引擎入口 wrapper：jstart 的 `[engine] init` 脚本，转发给
 * `basctl engine tomcat-dist`（jstart 只认脚本文件路径，不认 java 类）。
 */
string writeInitWrapper(string sasHome, string engineType) {
  auto binDir = buildPath(sasHome, "bin");
  mkdirRecurse(binDir);
  auto wrapper = buildPath(binDir, "basctl-" ~ engineType ~ "-dist-init.sh");
  auto lines = "#!/usr/bin/env bash\n"
    ~ "# Generated by basctl start: jstart [engine] init entry for the " ~ engineType ~ " dist engine.\n"
    ~ "exec " ~ shellQuote(basctlExecutable()) ~ " engine tomcat-dist \"$@\"\n";
  write(wrapper, lines);
  setExecutable(wrapper);
  return wrapper;
}

/** 运行中的 basctl 可执行文件路径（`/proc/self/exe`）；不可得时退回 PATH 上的 `basctl`。 */
string basctlExecutable() {
  version (linux) {
    try {
      auto self = readLink("/proc/self/exe");
      if (self.length)
        return self;
    } catch (Exception) {
      // 忽略：退回 PATH 查找
    }
  }
  auto fromEnv = strip(environment.get("sas_basctl", ""));
  return fromEnv.length ? fromEnv : "basctl";
}

/** 单引号包裹 shell 参数（内嵌单引号按 `'\''` 转义）。 */
string shellQuote(string s) {
  return "'" ~ s.replace("'", "'\\''") ~ "'";
}

/** `jstart resolve <spec>`：校验 spec 与各 webapp 的依赖是否齐备。 */
private bool resolveSpec(string spec) {
  auto res = execute([jstartCommand(), "resolve", spec], null, Config.stderrPassThrough);
  if (res.status != 0) {
    stderr.writeln("jstart resolve " ~ spec ~ " failed with exit code " ~ res.status.to!string);
    return false;
  }
  return true;
}

/** 后台启动：`nohup jstart run <spec>` 并把控制台输出写进日志，返回进程 pid（0 表示失败）。 */
private int launchBackground(string spec, string log) {
  mkdirRecurse(dirName(log));
  auto cmd = "nohup " ~ shellQuote(jstartCommand()) ~ " run " ~ shellQuote(spec)
    ~ " >> " ~ shellQuote(log) ~ " 2>&1 < /dev/null & echo $!";
  auto res = execute(["/bin/sh", "-c", cmd]);
  if (res.status != 0)
    return 0;
  auto text = strip(res.output);
  try
    return text.to!int;
  catch (Exception)
    return 0;
}

/** 实例控制台日志：`logs/<farm.server>/console.out`（`servers/<name>/logs` 为其软链）。 */
string consoleLog(string sasHome, Server server) {
  return buildPath(sasHome, "logs", server.qualifiedName, "console.out");
}

/** 运行中的实例 pid（`servers/<name>/SERVER_PID` 指向一个存活进程时）。 */
Nullable!int runningPid(string sasHome, Server server) {
  auto path = buildPath(sasHome, "servers", server.qualifiedName, "SERVER_PID");
  if (!exists(path))
    return Nullable!int.init;
  try {
    auto pid = strip(readText(path)).to!int;
    return processRunning(pid) ? nullable(pid) : Nullable!int.init;
  } catch (Exception) {
    return Nullable!int.init;
  }
}

/** 记录实例 pid（`servers/<name>/SERVER_PID`，供 `status`/`stop` 使用）。 */
private void writePidFile(string sasHome, Server server, int pid) {
  auto serverDir = buildPath(sasHome, "servers", server.qualifiedName);
  mkdirRecurse(serverDir);
  write(buildPath(serverDir, "SERVER_PID"), pid.to!string);
}

/** 启动前准备日志：`servers/<name>/logs` → `logs/<name>`，并归档旧 console.out。 */
private void prepareLog(string sasHome, Server server) {
  auto logDir = buildPath(sasHome, "logs", server.qualifiedName);
  mkdirRecurse(logDir);
  linkIfMissing(logDir, buildPath(sasHome, "servers", server.qualifiedName, "logs"));
  rollLog(sasHome, server);
}

/** 打印日志末尾若干行，方便一眼看出启动失败原因。 */
private void printLogTail(string log) {
  if (!exists(log))
    return;
  auto lines = readText(log).split("\n");
  auto from = lines.length > 20 ? lines.length - 20 : 0;
  foreach (line; lines[from .. $])
    stderr.writeln("  | " ~ line);
}
