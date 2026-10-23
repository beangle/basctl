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
 *     launch spec `servers/<farm.server>/launch.jstart`——一个 `<server>` 一个 JVM：
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
import bas.fsutil : linkIfMissing, mkdirPrivate;
import bas.jstart : jstartCommand;
import bas.logs : consoleLog, plainName, readTail;
import bas.net : canBindPort, localAddresses;
import bas.portalloc : PortRange, defaultPortRange, defaultPortRangeText, parsePortRange, reservePort;
import bas.resolver : resolveArtifact, resolveWebapps;
import bas.serverinfo : ServerInfo, WebappInfo, instancePid, liveInstancePid, liveInstances,
  localIsoTimestamp, readInstanceInfo, removeInstanceInfo, writeInstanceInfo;
import bas.serverstatus : instanceProcessIds, listeningProcessIds, pidLooksLikeInstance, processRunning,
  rollLog, signalProcess;
import bas.setline : SetlineConflict, conflictLines, runningPlan, setlinePlan;
import bas.setlineproc : syncRoutesToSetline;
import bas.spec : SubappSpec, engineInitCommand, renderLaunchSpec, shellQuote;

import core.thread : Thread;
import core.time : msecs;

import std.algorithm : canFind, map;
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

/** `service:*` 失败详情上限：完整日志仍由 `log:read` 提供。 */
private enum maxServiceDetailBytes = 8 * 1024;
private enum maxServiceLogLines = 100;
private enum maxServiceLogLineBytes = 1000;

/** 实例 launch spec 文件名；与 `engine-subapps.jstart` 等 jstart 固定约定分开。 */
private enum launchSpecFile = "launch.jstart";

/** `stop` 默认等进程退出的秒数（与 jstart 的历史缺省一致）。 */
enum defaultStopTimeoutSec = 15;

/**
 * `basctl start [server.xml] <farm|server|all> [--port-range=<from>-<to>]`：分配端口、写运行
 * 信息、生成 spec、resolve，然后后台启动。
 *
 * 任一实例准备失败只跳过该实例（写 `servers/<name>/error`，并撤销它的端口预留），其余照常启动。
 */
/** 本机 Host 是否启用了 setline。 */
private bool setlineEnabled(const Container container) {
  return localSetlineConfig(container, localAddresses()).enabled;
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
 * 不改启停的退出码：setline 挂了不该挡住应用启停，下一次启停（或手工 `basctl setline`）会补上。
 */
private void reconcileRoutes(const Container container, string basHome, bool noSetline) {
  if (noSetline)
    return;
  LocalSetline setline;
  try
    setline = localSetlineConfig(container, localAddresses());
  catch (Exception e) {
    stderr.writeln(e.msg);
    return;
  }
  if (!setline.enabled)
    return;
  auto plan = runningPlan(liveInstances(basHome));
  if (plan.conflicts.length) {
    printRouteConflicts(plan.conflicts);
    stderr.writeln("Routes not updated; fix the conflict and run `basctl setline --sync`.");
    return;
  }
  if (syncRoutesToSetline(plan.routes, setline.adminPort, setline.hostname, true) != 0)
    stderr.writeln("setline routes were not fully reconciled; the instances themselves are fine"
        ~ " (the next start/stop retries).");
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
  return startServers(container, basHome, servers, range, noSetline);
}

/**
 * 启动一组已经选好的本机实例；命令行与通道的 `service:start` 共用这一段。
 */
private int startServers(Container container, string basHome, Server[] servers,
    PortRange range, bool noSetline) {
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
  stderr.writeln("  With <setline> in server.xml the routes are reconciled after start (--no-setline skips it);");
  stderr.writeln("  with [remote] in conf/basctl.conf the host/instance snapshot is pushed once (best effort;");
  stderr.writeln("  see docs/channel-protocol.md).");
}

/**
 * `basctl make [server.xml] <farm|server|all>`：只准备不启动。
 *
 * 与 `start` 共用选实例、引擎默认与 {@link prepareServer}，逐个生成
 * `servers/<name>/launch.jstart` 并 `jstart resolve`（把依赖抓到本地库）；不写 pid、不起进程，
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
  stderr.writeln("  With <setline> in server.xml the routes are reconciled after stop (--no-setline skips it);");
  stderr.writeln("  with [remote] in conf/basctl.conf the host/instance snapshot is pushed once (best effort).");
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
  auto serverHome = buildPath(basHome, "servers", name);
  if (pid.isNull) {
    // 运行信息可能丢过，但进程还在（例如上一次启动在绑定端口前就写坏了 info）：
    // 按命令行里的 `-Dbas.server` + `-Dbas.home` 找回本实例，先停掉再让 restart 起新的。
    auto stale = instanceProcessIds(name, serverHome);
    if (stale.length == 0) {
      stderr.writeln(name ~ ": no run info (servers/" ~ name ~ "/server.info); "
          ~ "nothing basctl started is running.");
      return StopOutcome.notRunning;
    }
    return stopStaleProcesses(basHome, name, stale, force, timeoutSec);
  }
  if (!processRunning(pid.get)) {
    // 记录的 pid 已经没了，但同实例的进程可能还在（pid 被覆盖/手工 kill 错）：
    // 先按命令行把它停掉，而不是只删 info 留一个端口占用者。
    auto stale = instanceProcessIds(name, serverHome);
    if (stale.length > 0)
      return stopStaleProcesses(basHome, name, stale, force, timeoutSec);
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

/** 停掉按命令行找回的本实例残留进程；全部退出后清掉运行信息。 */
private StopOutcome stopStaleProcesses(string basHome, string name, const(int)[] stale,
    bool force, int timeoutSec) {
  writeln(name ~ ": stopping stale process(es) " ~ stale.map!(p => p.to!string).join(", "));
  foreach (p; stale)
    if (processRunning(p))
      signalProcess(p, force);
  bool failed;
  foreach (p; stale) {
    if (!waitForExit(p, timeoutSec)) {
      stderr.writeln(name ~ ": stale pid " ~ p.to!string ~ " did not exit in "
          ~ timeoutSec.to!string ~ "s; rerun with --force to SIGKILL it.");
      failed = true;
    }
  }
  if (failed)
    return StopOutcome.failed;
  removeRunInfo(basHome, name);
  writeln(name ~ ": stopped stale instance process(es).");
  return StopOutcome.stopped;
}

/** 控制通道 `service:*` 的结果，字段与 `docs/channel-protocol.md` 的应答一致。 */
struct ServiceResult {
  bool ok;
  string state;
  int pid;
  string error;
  string detail;
  string[] logTail;
  bool truncated;
}

/**
 * 执行控制通道的 `service:start|stop|restart`。
 *
 * 实例名来自控制台，只接受 `server.xml` 里本机声明的 `farm.server`；动作走固定的三个分支，
 * 不拼命令行、不把实例名交给 shell。`restart` 先在停机前准备一遍（与 `restart.sh` 的
 * resolve-before-stop 同构），避免依赖解析失败时已经停了服务；动态端口取停机前的运行信息，
 * 重启后保持原端口。
 */
ServiceResult serviceAction(string configFile, string action, string instance) {
  if (action != "start" && action != "stop" && action != "restart")
    return ServiceResult(false, "", 0, "bad-request");
  if (!plainName(instance))
    return ServiceResult(false, "", 0, "bad-request");
  if (!exists(configFile))
    return ServiceResult(false, "", 0, "no-config");

  Container container;
  try {
    container = parseServerXmlFile(configFile);
  } catch (Exception e) {
    return ServiceResult(false, "", 0, "bad-config: " ~ e.msg);
  }
  auto basHome = dirName(dirName(absolutePath(configFile)));

  Server target;
  foreach (server; localServers(container, instance))
    if (server.qualifiedName == instance)
      target = server;
  if (target is null)
    return ServiceResult(false, "", 0, "no-instance");
  applyEngineDefaults(container, [target]);

  auto previous = readInstanceInfo(basHome, instance);
  if (action == "restart" && !previous.isNull && target.http == 0)
    target.http = previous.get.httpPort;

  // 与 restart.sh 同序：准备失败就停在原处，不先停服务。
  if (action == "restart" && prepareServer(basHome, container, target).isNull) {
    auto result = ServiceResult(false, "", 0, "prepare-failed");
    attachFailureDetail(basHome, instance, result);
    return result;
  }

  if (action == "stop" || action == "restart") {
    final switch (stopInstance(basHome, target, false, defaultStopTimeoutSec)) {
    case StopOutcome.failed: {
      auto result = ServiceResult(false, "", 0, "stop-failed");
      attachFailureDetail(basHome, instance, result);
      return result;
    }
    case StopOutcome.stopped:
    case StopOutcome.notRunning:
      break;
    }
    reconcileRoutes(container, basHome, false);
    if (action == "stop")
      return ServiceResult(true, "stopped", 0, "");
  }

  if (startServers(container, basHome, [target], defaultPortRange, false) != 0) {
    auto result = ServiceResult(false, "", 0, "start-failed");
    attachFailureDetail(basHome, instance, result);
    return result;
  }
  // start 可能因「已按命令行找回本实例」而跳过，此时 server.info 里的旧 pid 可能是死的：
  // 以 liveInstancePid 为准，避免把已经运行着的实例回报成 start-failed。
  auto info = readInstanceInfo(basHome, instance);
  auto pid = liveInstancePid(basHome, instance);
  if (info.isNull || pid.isNull) {
    auto result = ServiceResult(false, "", 0, "start-failed");
    attachFailureDetail(basHome, instance, result);
    return result;
  }
  return ServiceResult(true, "running", pid.get, "");
}

/**
 * 给失败结果补上本机可读的详情：准备错误文件与实例 console.out 的尾部。
 *
 * `error` 保持稳定的机器码（`start-failed` 等），人类可读内容只放 `detail` / `logTail`，
 * 两者都限长；完整日志仍由控制台的 `log:read` 按需拉取。
 */
private void attachFailureDetail(string basHome, string instance, ref ServiceResult result) {
  auto errorFile = buildPath(basHome, "servers", instance, "error");
  if (exists(errorFile)) {
    try
      result.detail = truncateUtf8(strip(readText(errorFile)), maxServiceDetailBytes, result.truncated);
    catch (Exception)
      result.detail = "";
  }

  auto logPath = consoleLog(basHome, instance);
  if (!exists(logPath))
    return;
  try {
    auto window = readTail(logPath, maxServiceLogLines);
    if (window.total > maxServiceLogLines)
      result.truncated = true;
    foreach (line; window.lines) {
      bool lineTruncated;
      result.logTail ~= truncateUtf8(line, maxServiceLogLineBytes, lineTruncated);
      result.truncated = result.truncated || lineTruncated;
    }
  } catch (Exception) {
    result.logTail = [];
  }
}

/** 按字节截断 UTF-8 文本，避免切在多字节字符中间。 */
private string truncateUtf8(string text, size_t limit, ref bool truncated) {
  if (text.length <= limit)
    return text;
  auto cut = limit;
  while (cut > 0 && (cast(ubyte) text[cut] & 0xC0) == 0x80)
    cut--;
  truncated = true;
  return text[0 .. cut];
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
    // 固定端口先确认没人监听：Tomcat 的 connector 初始化失败只记日志、不会让进程退出，
    // 直接起会留下「进程活着但没有监听端口」的假实例，所以要在拉起前挡住。
    if (!canBindPort("", cast(ushort) server.http)) {
      auto message = name ~ ": port " ~ server.http.to!string ~ " is already in use";
      auto pids = instanceProcessIds(name, buildPath(basHome, "servers", name));
      if (pids.length > 0)
        message ~= "; stale instance process(es): " ~ pids.map!(p => p.to!string).join(", ");
      auto listeners = listeningProcessIds(cast(ushort) server.http);
      if (listeners.length > 0)
        message ~= "; listening pid(s): " ~ listeners.map!(p => p.to!string).join(", ");
      message ~= ". Stop the process holding the port and retry.";
      stderr.writeln(message);
      mkdirRecurse(buildPath(basHome, "servers", name));
      write(buildPath(basHome, "servers", name, "error"), message ~ "\n");
      return Nullable!ServerInfo.init;
    }
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
 * 与 `servers/<name>/launch.jstart`。成功返回 spec 路径，失败返回空。
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
  mkdirPrivate(serverDir);
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
  auto spec = instanceLaunchSpec(basHome, server.qualifiedName);
  mkdirRecurse(dirName(spec));
  write(spec, renderLaunchSpec(buildPath(basHome, "servers"), server.qualifiedName, basHome,
      initCommand, engineDeps, runtimeArgsFor(server), appArgs, subapps, entry));
  auto legacySpec = buildPath(basHome, "conf", server.qualifiedName ~ ".jstart");
  if (exists(legacySpec))
    remove(legacySpec);
  writeln(server.qualifiedName ~ ": wrote " ~ spec);
  if (!resolveSpec(spec, repoArgs(container)))
    return Nullable!string.init;
  return nullable(spec);
}

/** 实例 launch spec 的存放路径：`<basHome>/servers/<instance>/launch.jstart`。 */
string instanceLaunchSpec(string basHome, string instance) {
  return buildPath(basHome, "servers", instance, launchSpecFile);
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
 * `<snapshot-repo remote>`（快照仓库走独立的 `--snapshot-remote=`），token 合并为
 * `[token@]url` 随地址一起传递。
 * 都没配时不传，交给 jstart 的内置默认。
 */
string[] repoArgs(Container container) {
  string[] args;
  auto local = container.repository.local;
  if ((local.isNull || !strip(local.get).length) && !container.snapshotRepo.local.isNull)
    local = container.snapshotRepo.local;
  if (!local.isNull && strip(local.get).length)
    args ~= "--local=" ~ strip(local.get);
  if (container.repository.repoSpecs.length)
    args ~= "--remote=" ~ container.repository.repoSpecs.join(",");
  if (container.snapshotRepo.repoSpecs.length)
    args ~= "--snapshot-remote=" ~ container.snapshotRepo.repoSpecs.join(",");
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

/** 启动前准备日志：`servers/<name>/logs` → `logs/<name>`，并归档旧 console.out。 */
private void prepareLog(string basHome, Server server) {
  auto logDir = buildPath(basHome, "logs", server.qualifiedName);
  mkdirRecurse(logDir);
  linkIfMissing(logDir, buildPath(basHome, "servers", server.qualifiedName, "logs"));
  rollLog(basHome, server);
}

/**
 * 打印日志末尾若干行，方便一眼看出启动失败原因（读法与 `basctl logs` 同一条，
 * 见 {@link bas.logs.readTail}）。
 */
private void printLogTail(string log) {
  foreach (line; readTail(log, 20).lines)
    stderr.writeln("  | " ~ line);
}
