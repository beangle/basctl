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
 * `basctl start` / `basctl stop`：按 farm 准备并拉起/停止实例，同时维护实例运行信息。
 *
 * 启动沿用 bas「按 farm 启动」的语义，进程本身交给 jstart：
 *
 *  1. 从 `conf/server.xml` 选出匹配的本机 `<server>`（farm 名 / `farm.server` / `all`）；
 *  2. 定端口并写下第一段运行信息：`<server http>` 有值就用它，为 `0`（或缺省）时在
 *     `--port-range` 区间内分配一个空闲端口（见 {@link bas.portalloc}）；随后写
 *     `servers/<name>/server.info`（不含 pid，兼作端口预留，见 {@link bas.serverinfo}）；
 *  3. 逐个解析 webapp（沿用 `make`/`resolve` 的语义），为每个 `<server>` 生成一份
 *     launch spec `conf/<farm.server>.jstart`——一个 `<server>` 一个 JVM：
 *     `type="tomcat-server"` 时每个 webapp 一段 `[subapp <id>]`（各自 docBase 与 `libs`，
 *     依赖互不串味），`tomcat` / `undertow` / `jetty` 时写单应用 `[app] entry`（只允许一个 webapp）；
 *  4. `jstart resolve <spec>` 校验 spec 与依赖齐备；
 *  5. 后台 `jstart run <spec>`：jstart 先运行 `[engine] init`（按引擎 `type` 写成对应的
 *     `make tomcat-server` / `make tomcat` / `make undertow` / `make jetty`）→ 它准备容器
 *     环境并写出最终启动命令，jstart 再 exec；确认存活后把 pid 补进运行信息。
 *
 * 实例目录沿用 `servers/<farm.server>`——spec 里写 `[app] base = $BAS_HOME/servers`
 * 加 `[app] instance = <farm.server>`，jstart 的直接组件目录就是它；`logs/console.out`
 * 也与既有布局一致。运行信息把 pid、实际端口、webapp 与对外 url 集中在一份文件里，
 * `status` 与 setline 的路由对账都读它（见 docs/server-info.md）。
 *
 * `stop` 不再委托 `jstart stop`：pid 就在运行信息里，默认 SIGTERM 并按 `--timeout` 等待，
 * `--force` 才直接 SIGKILL。
 *
 * `basctl make <pattern>` 复用同一套准备流程（{@link prepareServer}），只生成 spec 并
 * `jstart resolve`，不起进程、不写运行信息。
 */
module bas.starter;

import bas.artifact : isMavenCoord, parseArtifact;
import bas.config;
import bas.fsutil : linkIfMissing;
import bas.jstart : jstartCommand;
import bas.net : localAddresses;
import bas.portalloc : PortRange, defaultPortRange, defaultPortRangeText, parsePortRange, reservePort;
import bas.resolver : resolveArtifact, resolveWebapps;
import bas.serverinfo : ServerInfo, WebappInfo, instancePid, liveInstancePid, liveInstances,
  localIsoTimestamp, readInstanceInfo, removeInstanceInfo, writeInstanceInfo;
import bas.serverstatus : pidLooksLikeInstance, processRunning, rollLog, signalProcess;
import bas.setline : SetlineConflict, conflictLines, runningPlan, setlinePlan;
import bas.setlineproc : syncRoutesToSetline;
import bas.spec : SubappSpec, engineInitCommand, renderLaunchSpec, shellQuote;

import core.thread : Thread;
import core.time : msecs;

import std.algorithm : canFind;
import std.array : join, split;
import std.conv : to;
import std.datetime.systime : Clock;
import std.file : exists, mkdirRecurse, readText, remove, write;
import std.format : format;
import std.path : absolutePath, buildPath, dirName;
import std.process : Config, environment, execute;
import std.stdio : stderr, writeln;
import std.string : startsWith, strip;
import std.typecons : Nullable, nullable;

/** 启动后等待多久（毫秒）再确认进程存活，用于 Webapp 启动失败/依赖缺失的快速反馈。 */
private enum startupProbeMs = 2000;

/** `stop` 默认等进程退出的秒数（与 jstart 的历史缺省一致）。 */
enum defaultStopTimeoutSec = 15;

/**
 * `basctl start [server.xml] <farm|server|all> [--port-range=<from>-<to>]`：分配端口、写运行
 * 信息、生成 spec、resolve，然后后台启动。
 *
 * 任一实例准备失败只跳过该实例（写 `servers/<name>/error`，并撤销它的端口预留），其余照常启动。
 */
/** `<setline>` 出现即启用（配置就是开关，见 docs/setline-config.md）。 */
private bool setlineEnabled(const Container container) {
  return !container.setlineListen.isNull && strip(container.setlineListen.get).length > 0;
}

/** 打印路由冲突与修法。 */
private void printRouteConflicts(const(SetlineConflict)[] conflicts) {
  foreach (line; conflictLines(conflicts))
    stderr.writeln(line);
  stderr.writeln("Give each webapp its own <url path=\"...\"/> so no two share a path.");
}

/**
 * 启停之后对账路由：把「现状」（`servers/<name>/server.info`）推给 setline。
 *
 * 路由跟着实例走，不跟着 `server.xml` 走——配置改了但实例没重启时，路由不该变。失败**只警告**，
 * 不改启停的退出码：setline 挂了不该挡住应用启停，下一个 `--sync` / `--watch` 周期会补上。
 */
private void reconcileRoutes(const Container container, string basHome, bool noSetline) {
  if (noSetline || !setlineEnabled(container))
    return;
  auto plan = runningPlan(liveInstances(basHome));
  if (plan.conflicts.length) {
    printRouteConflicts(plan.conflicts);
    stderr.writeln("Routes not updated; fix the conflict and run `basctl setline --sync`.");
    return;
  }
  if (syncRoutesToSetline(basHome, plan.routes, strip(container.setlineListen.get), true) != 0)
    stderr.writeln("Routes not updated (setline unavailable); the instances themselves are fine.");
}

int runStart(string configFile, string[] rest) {
  auto range = defaultPortRange;
  bool noSetline;
  auto pattern = startPattern(rest, range, noSetline);
  if (pattern.isNull)
    return 1;
  if (!exists(configFile)) {
    stderr.writeln("Cannot find config file " ~ configFile);
    return 1;
  }
  auto container = parseServerXmlFile(configFile);
  auto basHome = dirName(dirName(absolutePath(configFile)));
  auto servers = localServers(container, pattern.get);
  if (!servers.length) {
    stderr.writeln("No local server matches " ~ pattern.get);
    return 1;
  }

  applyEngineDefaults(container, servers);
  auto startedAt = localIsoTimestamp(Clock.currTime());

  // setline 启用时先把静态拓扑的冲突挡在启动前：同一条对外路径被端口集合不同的 webapp 认领，
  // 起来之后无法判定归属，与其起完再报错，不如一个都别起（动态端口要等分配完才知道，见尾部对账）。
  if (setlineEnabled(container) && !noSetline) {
    auto plan = setlinePlan(container);
    if (plan.conflicts.length) {
      printRouteConflicts(plan.conflicts);
      return 1;
    }
  }

  // 1. 先准备（分配端口 + 写运行信息 + 生成 spec + resolve），失败不启动，多个实例不会半启动
  PreparedServer[] prepared;
  int alreadyRunning, failed;
  foreach (server; servers) {
    auto pid = liveInstancePid(basHome, server.qualifiedName);
    if (!pid.isNull) {
      writeln(server.qualifiedName ~ " appears to still be running with PID " ~ pid.get.to!string
          ~ ". Start skipped.");
      alreadyRunning++;
      continue;
    }
    auto info = reserveInstance(basHome, container, server, range, startedAt);
    if (info.isNull) {
      failed++;
      continue;
    }
    auto spec = prepareServer(basHome, container, server);
    if (spec.isNull) {
      // 端口预留随失败的准备一起撤销，否则这个端口会被永久算作占用
      removeInstanceInfo(basHome, server.qualifiedName);
      failed++;
      continue;
    }
    prepared ~= PreparedServer(server, spec.get, info.get);
  }
  if (!prepared.length) {
    // 目标都已在运行（幂等重入）：视为成功；否则是准备失败
    if (!failed && alreadyRunning == servers.length)
      return 0;
    stderr.writeln("No instance was prepared; nothing started.");
    return 1;
  }

  // 2. 后台启动，再统一确认存活并补写 pid
  int[] pids;
  foreach (ref p; prepared) {
    prepareLog(basHome, p.server);
    pids ~= launchBackground(p.spec, consoleLog(basHome, p.server), repoArgs(container));
  }

  Thread.sleep(msecs(startupProbeMs));

  int started;
  foreach (i, ref p; prepared) {
    if (pids[i] > 0 && processRunning(pids[i])) {
      p.info.pid = pids[i];
      writeInstanceInfo(basHome, p.server.qualifiedName, p.info);
      writeln(format!"%s started (pid=%s, port=%s, log=%s)"(p.server.qualifiedName, pids[i],
          p.info.httpPort, consoleLog(basHome, p.server)));
      started++;
    } else {
      // 起不来的实例不留运行信息，否则端口会被算作占用、status 也看不到真相
      removeInstanceInfo(basHome, p.server.qualifiedName);
      stderr.writeln(p.server.qualifiedName ~ " failed to start, see " ~ consoleLog(basHome, p.server));
      printLogTail(consoleLog(basHome, p.server));
    }
  }
  writeln(started, " servers started.");
  reconcileRoutes(container, basHome, noSetline);
  return started == prepared.length && !failed ? 0 : 1;
}

/**
 * `start` 的位置参数与选项：`<farm|server|all>`、`--port-range=<from>-<to>` 与 `--no-setline`；
 * 给错即为空。
 */
private Nullable!string startPattern(const(string)[] args, ref PortRange range, ref bool noSetline) {
  string pattern;
  foreach (arg; args) {
    if (arg.startsWith("--port-range=")) {
      try
        range = parsePortRange(arg["--port-range=".length .. $]);
      catch (Exception e) {
        stderr.writeln(e.msg);
        return Nullable!string.init;
      }
    } else if (arg == "--no-setline") {
      noSetline = true;
    } else if (arg.startsWith("-")) {
      stderr.writeln("Unknown option " ~ arg);
      return Nullable!string.init;
    } else if (!pattern.length)
      pattern = arg;
    else {
      stderr.writeln("Too many arguments: " ~ arg);
      return Nullable!string.init;
    }
  }
  if (!pattern.length) {
    startUsage();
    return Nullable!string.init;
  }
  return nullable(pattern);
}

/** `start` 的用法。 */
private void startUsage() {
  stderr.writeln("Usage: basctl start [server.xml] <farm|server|all> [--port-range=<from>-<to>] [--no-setline]");
  stderr.writeln("  <server http=\"0\"> (or no http attribute) gets a free port from the range");
  stderr.writeln("  (default " ~ defaultPortRangeText ~ "), recorded in servers/<name>/server.info.");
  stderr.writeln("  With <setline> in server.xml the routes are reconciled after start (--no-setline skips it).");
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
 * `basctl stop [server.xml] <farm|server|all> [--force] [--timeout=<sec>]`：按运行信息里的 pid
 * 停止实例。
 *
 * pid 取自 `servers/<name>/server.info`，不再委托 `jstart stop`。默认 SIGTERM 并等 `--timeout`
 * 秒（缺省 15），进程不退时报错退出，加 `--force` 直接 SIGKILL（同时跳过身份核对）。停止后删除
 * 运行信息。
 */
int runStop(string configFile, string[] rest) {
  string pattern;
  bool force, noSetline;
  auto timeoutSec = defaultStopTimeoutSec;
  foreach (arg; rest) {
    if (arg == "--force")
      force = true;
    else if (arg == "--no-setline")
      noSetline = true;
    else if (arg.startsWith("--timeout=")) {
      try
        timeoutSec = parseTimeout(arg["--timeout=".length .. $]);
      catch (Exception e) {
        stderr.writeln(e.msg);
        return 1;
      }
    } else if (arg.startsWith("-")) {
      stopUsage();
      return 1;
    } else if (!pattern.length)
      pattern = arg;
    else {
      stopUsage();
      return 1;
    }
  }
  if (!pattern.length) {
    stopUsage();
    return 1;
  }
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

  int stopped, skipped;
  foreach (server; servers) {
    final switch (stopInstance(basHome, server, force, timeoutSec)) {
    case StopOutcome.stopped: stopped++; break;
    case StopOutcome.notRunning:
    case StopOutcome.failed: skipped++; break;
    }
  }
  writeln(stopped, " servers stopped.",
      skipped ? format!"(%s skipped)"(skipped) : "");
  reconcileRoutes(container, basHome, noSetline);
  return skipped ? 1 : 0;
}

/** `stop` 的用法。 */
private void stopUsage() {
  stderr.writeln("Usage: basctl stop [server.xml] <farm|server|all> [--force] [--timeout=<sec>] [--no-setline]");
  stderr.writeln("  SIGTERMs the pid recorded in servers/<name>/server.info and waits "
      ~ defaultStopTimeoutSec.to!string
      ~ "s by default; --force SIGKILLs at once.");
  stderr.writeln("  With <setline> in server.xml the routes are reconciled after stop (--no-setline skips it).");
}

/** 单个实例的停止结果。 */
private enum StopOutcome {
  /** 已发出信号并确认退出。 */
  stopped,
  /** 本来就没在跑（陈旧信息顺手清掉）。 */
  notRunning,
  /** 停不掉：进程不退、身份不符或发不出信号。 */
  failed,
}

/**
 * 停一个实例：先看运行信息，已经不在就直接清掉陈旧信息（重复 `stop` 不会越做越乱）。
 *
 * 默认先核对身份（{@link bas.serverstatus.pidLooksLikeInstance}）再发 SIGTERM——pid 会被系统
 * 回收，照着一个陈旧 pid 发信号可能伤及无辜。`--force` 跳过核对直接 SIGKILL，留作逃生门。
 */
private StopOutcome stopInstance(string basHome, Server server, bool force, int timeoutSec) {
  auto name = server.qualifiedName;
  auto pid = instancePid(basHome, name);
  if (pid.isNull) {
    stderr.writeln(name ~ ": no run info (servers/" ~ name ~ "/server.info); "
        ~ "nothing basctl started is running.");
    return StopOutcome.notRunning;
  }
  if (!processRunning(pid.get)) {
    removeRunInfo(basHome, name);
    writeln(name ~ ": not running; removed stale run info (pid=" ~ pid.get.to!string ~ ").");
    return StopOutcome.notRunning;
  }
  if (!force && !pidLooksLikeInstance(pid.get, name)) {
    stderr.writeln(name ~ ": pid " ~ pid.get.to!string ~ " does not look like this instance "
        ~ "(no -Dbas.server=" ~ name ~ " in its command line); leaving it alone. "
        ~ "Use --force to kill it anyway.");
    return StopOutcome.failed;
  }
  if (force) {
    if (!signalProcess(pid.get, true)) {
      stderr.writeln(name ~ ": cannot SIGKILL pid " ~ pid.get.to!string ~ ".");
      return StopOutcome.failed;
    }
    Thread.sleep(msecs(500));
    if (processRunning(pid.get)) {
      stderr.writeln(name ~ ": pid " ~ pid.get.to!string ~ " is still alive after SIGKILL.");
      return StopOutcome.failed;
    }
  } else {
    if (!signalProcess(pid.get, false)) {
      stderr.writeln(name ~ ": cannot SIGTERM pid " ~ pid.get.to!string ~ ".");
      return StopOutcome.failed;
    }
    if (!waitForExit(pid.get, timeoutSec)) {
      stderr.writeln(name ~ ": pid " ~ pid.get.to!string ~ " did not exit in "
          ~ timeoutSec.to!string ~ "s; rerun with --force to SIGKILL it.");
      return StopOutcome.failed;
    }
  }
  removeRunInfo(basHome, name);
  writeln(name ~ ": stopped (pid=" ~ pid.get.to!string ~ ").");
  return StopOutcome.stopped;
}

/** 等进程退出，最多 `timeoutSec` 秒；已经退出返回 true。 */
private bool waitForExit(int pid, int timeoutSec) {
  auto waited = 0;
  while (processRunning(pid) && waited < timeoutSec * 1000) {
    Thread.sleep(msecs(100));
    waited += 100;
  }
  return !processRunning(pid);
}

/** 删除实例的运行信息 `servers/<name>/server.info`。 */
private void removeRunInfo(string basHome, string name) {
  removeInstanceInfo(basHome, name);
}

/** 解析 `--timeout=<sec>`，非法或负数即抛异常。 */
private int parseTimeout(string text) {
  int seconds;
  try
    seconds = strip(text).to!int;
  catch (Exception)
    throw new Exception("Invalid timeout: " ~ text);
  if (seconds < 0)
    throw new Exception("Invalid timeout: " ~ text);
  return seconds;
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

/** 一个已备好 spec 的实例。 */
private struct PreparedServer {
  Server server;
  string spec;
  /** 启动前写下的运行信息（无 pid），确认存活后补上 pid 整文件重写。 */
  ServerInfo info;
}

/**
 * 启动前写第一段运行信息（不含 pid），兼作端口预留：动态端口在这里定下并回填 `server.http`，
 * 随后生成 spec 就能带上 `--port=`（与静态端口同一条参数）。
 *
 * 失败（区间没有空闲端口、拿不到端口锁）返回空，调用方跳过这个实例。
 */
private Nullable!ServerInfo reserveInstance(string basHome, Container container, Server server,
    PortRange range, string startedAt) {
  auto name = server.qualifiedName;
  auto info = describeInstance(container, server, startedAt);
  if (server.http > 0) {
    writeInstanceInfo(basHome, name, info);
    return nullable(info);
  }

  // 上次记录的端口（可能是崩溃残留）：重启后优先复用它，端口稳定，书签与路由都不用重记
  auto previous = readInstanceInfo(basHome, name);
  auto reservation = reservePort(basHome, name, range, previous.isNull ? 0 : previous.get.httpPort,
      (port) {
        auto reserved = info;
        reserved.httpPort = port;
        writeInstanceInfo(basHome, name, reserved);
      });
  if (reservation.port.isNull) {
    stderr.writeln(name ~ ": cannot allocate a port, " ~ reservation.reason);
    return Nullable!ServerInfo.init;
  }
  info.httpPort = reservation.port.get;
  // 回填到 server：spec 的 `--port=` 由 `appArgsFor(server)` 拼出，读的就是这个字段；不回填的
  // 话动态端口只写进了运行信息，应用却还在用引擎的缺省端口（路由会指到一个没人听的端口）。
  server.http = info.httpPort;
  writeln(format!"%s: port %s (range %s)"(name, info.httpPort, range));
  return nullable(info);
}

/**
 * 由配置推导实例运行信息：id / engine（`<type>-<version>`）/ http 端口 / 各 webapp 及其对外 url。
 *
 * webapp 段的 id 与 launch spec 的 `[subapp <id>]` 同源（都由 context path 推导），运行信息与
 * spec 因此能按 id 对上号；`url` 未声明时读者回退 `context`，与路由渲染的规则一致。
 */
ServerInfo describeInstance(Container container, Server server, string startedAt) {
  ServerInfo info;
  info.id = server.qualifiedName;
  info.engine = engineRefText(server.farm.engine);
  info.httpPort = server.http > 0 ? cast(ushort) server.http : 0;
  info.started = startedAt;
  string[] used;
  foreach (app; container.getWebapps(server)) {
    auto id = subappId(app.contextPath, used);
    used ~= id;
    info.webapps ~= WebappInfo(id, app.uri, app.contextPath.length ? app.contextPath : "/",
        app.urls.dup);
  }
  return info;
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
