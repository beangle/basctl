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
 * 沿用 bas「按 farm 启动」的语义，启动本身交给 jstart：
 *
 *  1. 从 `conf/server.xml` 选出匹配的本机 `<server>`（farm 名 / `farm.server` / `all`）；
 *  2. 逐个解析 webapp（沿用 `make`/`resolve` 的语义），为每个 `<server>` 生成一份
 *     launch spec `conf/<farm.server>.jstart`——一个 `<server>` 一个 JVM：
 *     `type="tomcat-server"` 时每个 webapp 一段 `[subapp <id>]`（各自 docBase 与 `libs`，
 *     依赖互不串味），`tomcat` / `undertow` / `jetty` 时写单应用 `[app] entry`（只允许一个 webapp）；
 *  3. `jstart resolve <spec>` 校验 spec 与依赖齐备；
 *  4. 后台 `jstart run <spec>`：jstart 先运行 `[engine] init`（按引擎 `type` 写成对应的
 *     `make tomcat-server` / `make tomcat` / `make undertow` / `make jetty`）→ 它准备容器
 *     环境并写出最终启动命令，jstart 再 exec。
 *
 * 实例目录沿用 `servers/<farm.server>`——spec 里写 `[app] base = $BAS_HOME/servers`
 * 加 `[app] instance = <farm.server>`，jstart 的直接组件目录就是它；`SERVER_PID` 与
 * `logs/console.out` 也与既有布局一致。
 *
 * `basctl make <pattern>` 复用同一套准备流程（{@link prepareServer}），只生成 spec 并
 * `jstart resolve`，不起进程。
 */
module bas.starter;

import bas.artifact : isMavenCoord, parseArtifact;
import bas.config;
import bas.fsutil : linkIfMissing;
import bas.jstart : jstartCommand;
import bas.net : localAddresses;
import bas.resolver : resolveArtifact, resolveWebapps;
import bas.serverstatus : processRunning, rollLog;
import bas.spec : SubappSpec, engineInitCommand, renderLaunchSpec, shellQuote;

import core.thread : Thread;
import core.time : msecs;

import std.algorithm : canFind;
import std.array : join, split;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, remove, write;
import std.format : format;
import std.path : absolutePath, buildPath, dirName;
import std.process : Config, environment, execute;
import std.stdio : stderr, writeln;
import std.string : strip;
import std.typecons : Nullable, nullable;

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
  auto basHome = dirName(dirName(absolutePath(configFile)));
  auto servers = localServers(container, pattern);
  if (!servers.length) {
    stderr.writeln("No local server matches " ~ pattern);
    return 1;
  }

  applyEngineDefaults(container, servers);

  // 1. 先准备（生成 spec + resolve），失败不启动；这样多个实例不会半启动
  PreparedServer[] prepared;
  int alreadyRunning;
  foreach (server; servers) {
    auto pid = runningPid(basHome, server);
    if (!pid.isNull) {
      writeln(server.qualifiedName ~ " appears to still be running with PID " ~ pid.get.to!string
          ~ ". Start skipped.");
      alreadyRunning++;
      continue;
    }
    auto spec = prepareServer(basHome, container, server);
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
    prepareLog(basHome, p.server);
    pids ~= launchBackground(p.spec, consoleLog(basHome, p.server), repoArgs(container));
  }

  Thread.sleep(msecs(startupProbeMs));

  int started;
  foreach (i, ref p; prepared) {
    if (pids[i] > 0 && processRunning(pids[i])) {
      writePidFile(basHome, p.server, pids[i]);
      writeln(format!"%s started (pid=%s, log=%s)"(p.server.qualifiedName, pids[i],
          consoleLog(basHome, p.server)));
      started++;
    } else {
      stderr.writeln(p.server.qualifiedName ~ " failed to start, see " ~ consoleLog(basHome, p.server));
      printLogTail(consoleLog(basHome, p.server));
    }
  }
  writeln(started, " servers started.");
  return started == prepared.length ? 0 : 1;
}

/**
 * `basctl make [server.xml] <farm|server|all>`：只准备不启动。
 *
 * 与 `start` 共用选实例、引擎默认与 {@link prepareServer}，逐个生成
 * `conf/<name>.jstart` 并 `jstart resolve`（把依赖抓到本地库）；不写 pid、不起进程，
 * 启动交给 `start`。适合离线预取与启动前巡检。
 */
int runMake(string configFile, string pattern) {
  if (!exists(configFile)) {
    stderr.writeln("Cannot find config file " ~ configFile);
    return 1;
  }
  auto container = parseServerXmlFile(configFile);
  auto basHome = dirName(dirName(absolutePath(configFile)));
  auto servers = localServers(container, pattern);
  if (!servers.length) {
    stderr.writeln("No local server matches " ~ pattern);
    return 1;
  }
  applyEngineDefaults(container, servers);

  int prepared, failed;
  foreach (server; servers) {
    if (prepareServer(basHome, container, server).isNull)
      failed++;
    else
      prepared++;
  }
  writeln(prepared, " servers prepared", failed ? format!", %s failed"(failed) : "", ".");
  return failed ? 1 : 0;
}

/** 给选中的 server 所引用的引擎补齐 bas 默认（每个引擎一次）。 */
private void applyEngineDefaults(Container container, const(Server)[] servers) {
  Engine[] engines;
  foreach (farm; container.farms)
    foreach (server; farm.servers)
      if (servers.canFind(server) && !engines.canFind(farm.engine))
        engines ~= farm.engine;
  foreach (engine; engines)
    applyEngineDefault(container, engine);
}

/**
 * `basctl stop [server.xml] <farm|server|all> [--force] [--timeout=<sec>]`：
 * 逐个 `jstart stop conf/<name>.jstart`，与 `start` 生成/使用同一份 spec。
 *
 * 实例由 jstart 记录 pid；本命令不直接杀进程，`--force`/`--timeout` 原样交给 jstart。
 */
int runStop(string configFile, string[] rest) {
  if (!rest.length) {
    stderr.writeln("Usage: basctl stop [server.xml] <farm|server|all> [--force] [--timeout=<sec>]");
    return 1;
  }
  if (!exists(configFile)) {
    stderr.writeln("Cannot find config file " ~ configFile);
    return 1;
  }
  auto container = parseServerXmlFile(configFile);
  auto basHome = dirName(dirName(absolutePath(configFile)));
  auto servers = localServers(container, rest[0]);
  if (!servers.length) {
    stderr.writeln("No local server matches " ~ rest[0]);
    return 1;
  }
  auto extra = rest[1 .. $];

  int stopped, skipped;
  foreach (server; servers) {
    auto spec = buildPath(basHome, "conf", server.qualifiedName ~ ".jstart");
    if (!exists(spec)) {
      stderr.writeln(server.qualifiedName ~ ": no spec " ~ spec
          ~ " (started outside basctl? use the legacy stop.sh)");
      skipped++;
      continue;
    }
    auto res = execute([jstartCommand(), "stop", spec] ~ extra, null,
        Config.stderrPassThrough);
    if (res.status != 0) {
      stderr.writeln(server.qualifiedName ~ ": jstart stop failed with exit code "
          ~ res.status.to!string);
      skipped++;
      continue;
    }
    writeln(server.qualifiedName ~ ": stopped");
    removeStalePid(basHome, server);
    stopped++;
  }
  writeln(stopped, " servers stopped.",
      skipped ? format!"(%s skipped)"(skipped) : "");
  return skipped ? 1 : 0;
}

/** 选择部署在本机、且匹配 pattern（`all` / farm 名 / `farm.server`）的 server。 */
Server[] localServers(Container container, string pattern) {
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
  return servers;
}

/** 停止后清理残留 `SERVER_PID`（进程已不在时）。 */
private void removeStalePid(string basHome, Server server) {
  auto path = buildPath(basHome, "servers", server.qualifiedName, "SERVER_PID");
  if (!exists(path))
    return;
  try {
    auto pid = strip(readText(path)).to!int;
    if (!processRunning(pid))
      remove(path);
  } catch (Exception) {
    // 内容非法时保留，交给 status/用户排查
  }
}

/** 一个已备好 spec 的实例。 */
private struct PreparedServer {
  Server server;
  string spec;
}

/**
 * 为单个 `<server>` 生成 spec：解析 webapp、确保引擎依赖本地齐备、写出 `[engine] init` 命令行
 * 与 `conf/<name>.jstart`。成功返回 spec 路径，失败返回空。
 */
private Nullable!string prepareServer(string basHome, Container container, Server server) {
  auto webapps = container.getWebapps(server);
  if (!webapps.length) {
    writeln(server.qualifiedName ~ ": no webapp deployed, skipped.");
    return Nullable!string.init;
  }

  auto engine = server.farm.engine;
  string containerType;
  try {
    containerType = containerTypeOf(engine);
  } catch (ServerXmlException e) {
    stderr.writeln(server.qualifiedName ~ ": " ~ e.msg);
    return Nullable!string.init;
  }
  bool standalone = containerType != containerTypeTomcatServer;
  auto standaloneError = standaloneWebappError(containerType, engine.name, webapps.length);
  if (standaloneError.length) {
    stderr.writeln(server.qualifiedName ~ ": " ~ standaloneError);
    return Nullable!string.init;
  }

  auto serverDir = buildPath(basHome, "servers", server.qualifiedName);
  auto errorFile = buildPath(serverDir, "error");
  auto missings = resolveWebapps(basHome, container.repository, container.snapshotRepo, webapps);
  mkdirRecurse(serverDir);
  if (missings.length) {
    write(errorFile, missings.join("\n"));
    stderr.writeln("Cannot resolve " ~ server.qualifiedName ~ ", see details: " ~ errorFile);
    return Nullable!string.init;
  }
  if (exists(errorFile))
    remove(errorFile);

  string[] engineDeps;
  if (!collectEngineDeps(container, engine, containerType, container.repository, container.snapshotRepo,
      engineDeps))
    return Nullable!string.init;

  auto appArgs = appArgsFor(server);
  string entry;
  const(SubappSpec)[] subapps;
  if (standalone) {
    entry = webapps[0].docBase;
    if (webapps[0].contextPath.length)
      appArgs ~= "--path=" ~ webapps[0].contextPath;
  } else {
    subapps = subappSpecs(webapps);
  }

  auto initCommand = engineInitCommand(containerType);
  auto spec = buildPath(basHome, "conf", server.qualifiedName ~ ".jstart");
  mkdirRecurse(dirName(spec));
  write(spec, renderLaunchSpec(buildPath(basHome, "servers"), server.qualifiedName, basHome,
      initCommand, engineDeps, runtimeArgsFor(server), appArgs, subapps, entry));
  writeln(server.qualifiedName ~ ": wrote " ~ spec);
  if (!resolveSpec(spec, repoArgs(container)))
    return Nullable!string.init;
  return nullable(spec);
}

/**
 * 嵌入式引擎（`tomcat` / `undertow` / `jetty`）只运行一个 webapp；部署多个时返回给运维看的错误信息，合法时返回空串。
 */
string standaloneWebappError(string containerType, string engineName, size_t webappCount) {
  if (containerType != containerTypeTomcatServer && webappCount > 1)
    return "engine " ~ engineName ~ " type=\"" ~ containerType ~ "\" runs a single webapp, but "
      ~ webappCount.to!string ~ " are deployed; use type=\"" ~ containerTypeTomcatServer ~ "\"";
  return "";
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

/** `[runtime]`：bas 的 JVM 默认参数 + `<farm><server-options>`。 */
string[] runtimeArgsFor(Server server) {
  auto farm = server.farm;
  auto heap = server.maxHeapSize.length ? server.maxHeapSize : "300M";
  string[] args = ["-server", "-Djava.awt.headless=true", "-Xmx" ~ heap,
    "-Djava.security.egd=file:/dev/./urandom", "-Dbas.server=" ~ server.qualifiedName];
  if (!farm.serverOptions.isNull) {
    foreach (line; farm.serverOptions.get.split("\n")) {
      auto one = strip(line);
      if (one.length)
        args ~= one;
    }
  }
  return args;
}

/** `[args]`：透传给容器入口的参数（端口、JSP 开关与 `<http>` 连接器参数）。 */
string[] appArgsFor(Server server) {
  string[] args;
  if (server.http > 0)
    args ~= "--port=" ~ server.http.to!string;
  // JSP 只对 tomcat-server（全量发行包）有意义：嵌入式引擎固定屏蔽 Jasper SCI
  if (server.farm.engine.jspSupport && server.farm.engine.typ == containerTypeTomcatServer)
    args ~= "--jsp=true";
  args ~= connectorArgs(server.farm.http);
  return args;
}

/**
 * `<http>` 连接器参数 → 引擎属性（`--Dconnector.*`）。嵌入式引擎直接消费；
 * `tomcat-server` 由 creator 渲染进 `conf/server.xml` 的 `<Connector>`。
 * `accept-count` / `max-connections` 只覆盖显式给出的项，其余取 basctl 的缺省值。
 */
private string[] connectorArgs(HttpConnector http) {
  string[] args = [
    "--Dconnector.enableLookups=" ~ (http.enableLookups ? "true" : "false"),
    "--Dconnector.disableUploadTimeout=" ~ (http.disableUploadTimeout ? "true" : "false"),
    "--Dconnector.connectionTimeout=" ~ http.connectionTimeout.to!string
  ];
  if (!http.acceptCount.isNull)
    args ~= "--Dconnector.acceptCount=" ~ http.acceptCount.get.to!string;
  if (!http.maxConnections.isNull)
    args ~= "--Dconnector.maxConnections=" ~ http.maxConnections.get.to!string;
  return args;
}

/**
 * `[engine]` 依赖行：`engines.ini` 中该容器类型的默认集（展开 `{version}` / `{bas}`）
 * 与 `<engine><jar>` 合并的结果——GA 相同覆盖，其余追加（见 {@link resolveEngineDeps}）。
 *
 * 逐条校验确保本地齐备（gav 走 jstart fetch），缺失即失败——避免 `run` 阶段才发现。
 */
bool collectEngineDeps(Container container, Engine engine, string containerType, Repository repo,
    SnapshotRepo snapshotRepo, ref string[] deps) {
  deps ~= resolveEngineDeps(container, engine, containerType);
  foreach (dep; deps) {
    if (!isMavenCoord(dep))
      continue;
    auto artifact = parseArtifact(dep);
    if (resolveArtifact(repo, snapshotRepo, artifact).isNull) {
      stderr.writeln("Cannot resolve engine dependency " ~ dep);
      return false;
    }
  }
  return true;
}

/** 把 argv 拼成一条 shell 命令（每个参数单独加引号）。 */
private string shellJoin(const(string)[] args) {
  string[] quoted;
  foreach (arg; args)
    quoted ~= shellQuote(arg);
  return quoted.join(" ");
}

/**
 * 调用 jstart（`resolve` / `run`）时的仓库参数：本地库取 `<repository local>`，
 * 缺省退回 `<snapshot-repo local>`；上游分别是 `<repository remote>` 与
 * `<snapshot-repo remote>`（快照仓库走独立的 `--snapshot-remote=`）。
 * 都没配时不传，交给 jstart 的内置默认。
 */
string[] repoArgs(Container container) {
  string[] args;
  auto local = container.repository.local;
  if ((local.isNull || !strip(local.get).length) && !container.snapshotRepo.local.isNull)
    local = container.snapshotRepo.local;
  if (!local.isNull && strip(local.get).length)
    args ~= "--local=" ~ strip(local.get);
  if (container.repository.remotes.length)
    args ~= "--remote=" ~ container.repository.remotes.join(",");
  if (container.snapshotRepo.remotes.length)
    args ~= "--snapshot-remote=" ~ container.snapshotRepo.remotes.join(",");
  return args;
}

/** `jstart [repo] resolve <spec>`：校验 spec 与各 webapp 的依赖是否齐备。 */
private bool resolveSpec(string spec, const(string)[] repos) {
  auto res = execute([jstartCommand()] ~ repos ~ ["resolve", spec], null, Config.stderrPassThrough);
  if (res.status != 0) {
    stderr.writeln("jstart resolve " ~ spec ~ " failed with exit code " ~ res.status.to!string);
    return false;
  }
  return true;
}

/** 后台启动：`nohup jstart run <spec>` 并把控制台输出写进日志，返回进程 pid（0 表示失败）。 */
private int launchBackground(string spec, string log, const(string)[] repos) {
  mkdirRecurse(dirName(log));
  auto cmd = "nohup " ~ shellJoin([jstartCommand()] ~ repos ~ ["run", spec])
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
string consoleLog(string basHome, Server server) {
  return buildPath(basHome, "logs", server.qualifiedName, "console.out");
}

/** 运行中的实例 pid（`servers/<name>/SERVER_PID` 指向一个存活进程时）。 */
Nullable!int runningPid(string basHome, Server server) {
  auto path = buildPath(basHome, "servers", server.qualifiedName, "SERVER_PID");
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
private void writePidFile(string basHome, Server server, int pid) {
  auto serverDir = buildPath(basHome, "servers", server.qualifiedName);
  mkdirRecurse(serverDir);
  write(buildPath(serverDir, "SERVER_PID"), pid.to!string);
}

/** 启动前准备日志：`servers/<name>/logs` → `logs/<name>`，并归档旧 console.out。 */
private void prepareLog(string basHome, Server server) {
  auto logDir = buildPath(basHome, "logs", server.qualifiedName);
  mkdirRecurse(logDir);
  linkIfMissing(logDir, buildPath(basHome, "servers", server.qualifiedName, "logs"));
  rollLog(basHome, server);
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
