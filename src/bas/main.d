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
 * basctl 命令行入口：`version` / `banner` / `status` / `logs` / `init` / `make` / `resolve` /
 * `start` / `stop` / `run` / `setline` / `doctor` / `firewall` / `pull` / `report` / `agent`。
 *
 * `start` / `stop` 在 `server.xml` 配了 `<setline>` 时还会自动对账路由（见 bas.setlineproc），
 * `--no-setline` 可临时跳过。
 */
module bas.main;

import bas.agent : runAgent, runReport;
import bas.banner;
import bas.config;
import bas.doctor : runDoctor;
import bas.embed : defaultBasVersion, runEmbedded;
import bas.endpoint : adminAddress, portFree, resolveSetlinePort;
import bas.enginecreator;
import bas.firewall;
import bas.init;
import bas.logs : runLogs;
import bas.net;
import bas.pull;
import bas.shellenv : readContainer;
import bas.resolver;
import bas.serverinfo : ServerInfo, liveInstances, readInstanceInfo;
import bas.serverstatus;
import bas.setline : SetlineConflict, conflictLines, parseRouteTable, routeDriftLines, runningPlan;
import bas.setlineproc : RouteRead, fetchRouteTable, syncRoutesToSetline;
import bas.starter;

import std.algorithm : canFind, sort;
import std.conv : to;
import std.file : SpanMode, dirEntries, exists, isDir, mkdirRecurse, readText, write;
import std.format : format;
import std.path : absolutePath, baseName, buildPath, dirName;
import std.process : environment;
import std.stdio : stderr, stdout, writeln;
import std.string : endsWith, join, leftJustify, startsWith, strip;

/** CLI 自身版本，随发布更新。 */
enum basctlVersion = "0.0.1";

version (unittest) {
} else {
  int main(string[] args) {
    if (args.length < 2) {
      printUsage();
      return 1;
    }
    try
      return dispatch(args);
    catch (Exception e) {
      // 配置与解析类错误（如 <setline> 缺 port）在这里落成一行，
      // 而不是把 D 的调用栈丢给操作者。
      stderr.writeln("basctl: ", e.msg);
      return 1;
    }
  }

  /** 按子命令分派；可恢复的错误统一由 {@link main} 收口。 */
  private int dispatch(string[] args) {
    switch (args[1]) {
    case "version", "-v", "--version":
      return cmdVersion();
    case "banner":
      return cmdBanner(args[2 .. $]);
    case "status":
      return cmdStatus();
    case "logs": {
      auto rest = args[2 .. $];
      return runLogs(dirName(dirName(absolutePath(takeConfigFile(rest)))), rest);
    }
    case "init":
      return runInit(args[2 .. $]);
    case "make":
      return cmdMake(args[2 .. $]);
    case "resolve":
      return cmdResolve(args[2 .. $]);
    case "start": {
      auto rest = args[2 .. $];
      return runStart(takeConfigFile(rest), rest);
    }
    case "stop": {
      auto rest = args[2 .. $];
      return runStop(takeConfigFile(rest), rest);
    }
    case "run":
      return runEmbedded(args[2 .. $]);
    case "setline":
      return cmdSetline(args[2 .. $]);
    case "doctor": {
      auto rest = args[2 .. $];
      return runDoctor(takeConfigFile(rest));
    }
    case "firewall":
      return runFirewall(args[1 .. $]);
    case "pull":
      return runPull(args[2 .. $]);
    case "report": {
      auto rest = args[2 .. $];
      return runReport(takeConfigFile(rest), basctlVersion, rest);
    }
    case "agent": {
      auto rest = args[2 .. $];
      return runAgent(takeConfigFile(rest), basctlVersion, rest);
    }
    case "help", "-h", "--help":
      printUsage();
      return 0;
    default:
      stderr.writeln("Unknown command: ", args[1]);
      printUsage();
      return 1;
    }
  }
}

private:

/** 打印命令用法到 stderr。 */
void printUsage() {
  stderr.writeln("Usage: basctl <command> [args]");
  stderr.writeln("Commands:");
  stderr.writeln("  version                       Show the basctl version");
  stderr.writeln("  banner [server.xml]           Show logo, versions and local hosts (used by bas.sh version)");
  stderr.writeln("  status                        Show running servers under $BAS_HOME/servers");
  stderr.writeln("  logs [server.xml] <instance>  Print the tail of logs/<instance>/console.out");
  stderr.writeln("                                (-n <lines> default 50, -f to keep following)");
  stderr.writeln("  init [--force] [workdir]      Install the control scripts under <workdir>/bin");
  stderr.writeln("  make [server.xml] <pattern>   Generate specs and resolve dependencies (no start)");
  stderr.writeln("  make <type> [options]         Prepare a container for jstart `[engine] init` (creator)");
  stderr.writeln("  resolve <server.xml> [pattern...]  Resolve webapps only");
  stderr.writeln("  start [server.xml] <pattern>  Allocate ports, generate a jstart spec per server and start it");
  stderr.writeln("                                (--port-range=<from>-<to>, default 20000-29999, when");
  stderr.writeln("                                <server http=\"0\">: basctl picks and records the port;");
  stderr.writeln("                                --no-setline: do not register routes)");
  stderr.writeln("  stop [server.xml] <pattern>   Stop the instances started by `start` (pid from server.info)");
  stderr.writeln("                                (--timeout=<sec> default 15, --force: SIGKILL at once;");
  stderr.writeln("                                --no-setline: do not unregister routes)");
  stderr.writeln("  run [options] <app>           Run one webapp in embedded mode");
  stderr.writeln("                                (--engine=<type>-<version>, e.g. tomcat-11.0.25;");
  stderr.writeln("                                bas engine version defaults to " ~ defaultBasVersion ~ ")");
  stderr.writeln("  setline [server.xml]          Push the live instances' routes to the running");
  stderr.writeln("                                setline (basctl never renders setline's own config)");
  stderr.writeln("                                (routes under <setline hostname>; admin address");
  stderr.writeln("                                from <setline port>, the only source;");
  stderr.writeln("                                one shot, no --watch)");
  stderr.writeln("  doctor [server.xml]           Check that java / jstart are on this machine");
  stderr.writeln("                                (setline too, but only when <setline> is configured)");
  stderr.writeln("  firewall [workdir]            Configure firewalld ports from conf/server.xml");
  stderr.writeln("  pull [--file=<basctl.conf>] [workdir]  Fetch conf/server.xml from the control endpoint");
  stderr.writeln("  report [server.xml]           Push one host/instance snapshot to the hub and exit");
  stderr.writeln("  agent [server.xml]            Stay connected to the hub: periodic reports, log reads,");
  stderr.writeln("                                and the fixed service actions (see docs/channel-protocol.md)");
}

/**
 * `make`：两种输入，同一种「准备」语义——
 *
 *  - `make <tomcat-server|tomcat|undertow|jetty> [协议参数]`：jstart `[engine] init`
 *    的回调（creator），准备容器环境并写出最终启动命令；
 *  - `make [server.xml] <farm|server|all>`：按配置只准备不启动，生成 spec 并
 *    `jstart resolve`（预取依赖）。
 */
private int cmdMake(string[] args) {
  if (!args.length) {
    makeUsage();
    return 1;
  }
  if (isContainerType(args[0]))
    return runEngineCreator(args);
  if (args.length == 1)
    return runMake(buildPath(resolveBasHome(), "conf", "server.xml"), args[0]);
  if (args.length == 2)
    return runMake(args[0], args[1]);
  makeUsage();
  return 1;
}

/** `make` 的用法（creator 模式与只准备模式）。 */
private void makeUsage() {
  stderr.writeln("Usage: basctl make <tomcat-server|tomcat|undertow|jetty> [options]");
  stderr.writeln("       basctl make [server.xml] <farm|server|all>");
  stderr.writeln("  <type> mode is the jstart `[engine] init` callback; the <pattern> mode only");
  stderr.writeln("  generates specs and resolves dependencies, start them with `basctl start`.");
}

/** `version`：纯文本版本，便于脚本取值（`basctl 0.0.1`）。 */
int cmdVersion() {
  writeln("basctl " ~ basctlVersion);
  return 0;
}

/**
 * `banner [server.xml]`：面向操作者的横幅（logo + 版本行 + 本机地址），由 `bas.sh version` 调用。
 *
 * 未给 server.xml 时取 `$BAS_HOME/conf/server.xml`；能给到 `<bas version>` 就显示 bas 引擎版本，
 * 文件缺失或解析失败则退化为只显示 basctl 版本。
 */
int cmdBanner(string[] args) {
  auto confFile = args.length ? args[0] : buildPath(resolveBasHome(), "conf", "server.xml");
  writeln(banner(basctlVersion, deployedBasVersion(confFile)));
  return 0;
}

/**
 * 读取 server.xml 的 `<bas version>`（部署所用的 bas 引擎版本）：文件缺失或解析失败都返回空串，
 * 横幅据此退化为只显示 basctl 版本（避免拿不到配置时把 basctl 的版本当成 bas 引擎版本）。
 */
private string deployedBasVersion(string confFile) {
  if (!exists(confFile))
    return "";
  try
    return parseServerXmlFile(confFile).version_;
  catch (Exception)
    return "";
}

/** 解析配置文件中的 webapp（`resolve` 命令）。 */
int cmdResolve(string[] args) {
  if (!args.length) {
    stderr.writeln("Usage: basctl resolve /path/to/conf/server.xml [farm|server|all]...");
    return -1;
  }
  auto configFile = args[0];
  if (!exists(configFile)) {
    stderr.writeln("Cannot find config file " ~ configFile);
    return -1;
  }
  auto container = parseServerXmlFile(configFile);
  auto basHome = absolutePath(buildPath(configFile, "..", ".."));

  auto patterns = args[1 .. $];
  auto ips = localAddresses();
  Webapp[] webapps;
  bool all = !patterns.length;
  foreach (p; patterns) {
    if (p == "all")
      all = true;
  }

  foreach (farm; container.farms) {
    foreach (server; farm.servers) {
      if (!ips.canFind(server.host.ip))
        continue;
      bool matched = all;
      foreach (p; patterns) {
        if (p == "all" || p == farm.name || p == server.qualifiedName) {
          matched = true;
          break;
        }
      }
      if (matched) {
        foreach (webapp; container.getWebapps(server)) {
          if (!webapps.canFind(webapp))
            webapps ~= webapp;
        }
      }
    }
  }

  auto missing = resolveWebapps(basHome, container.repository, container.snapshotRepo, webapps);
  return missing.length ? -1 : 0;
}

/**
 * `setline [server.xml]`：把**运行中实例**的整组路由推给 setline（本地 HTTP 路径路由器）——
 * 幂等，只替换本 `BAS_HOME` 命名空间那一格。
 *
 * setline 是独立的机器级服务（systemd / 容器入口 / 手工拉起），自己那份配置（`listen` /
 * `adminListen` / 调参）不归 basctl 生成：basctl **只推路由**，不写出任何文件，也不拉起进程。
 *
 * 路由从「现状」（`servers/<name>/server.info`）算，不重新解析 `server.xml`：配置改了但实例没重启时
 * 路由不该跟着变，动态端口也只有运行信息里才有。同一路径被端口集合不同的多个 webapp 认领时无法
 * 判定归属，打印冲突并退出，不推任何路由。
 *
 * 缺省 server.xml 取 `$BAS_HOME/conf/server.xml`，路由落在 `<setline hostname>` 命名空间下（缺省
 * `localhost`，`*` 表示任意 Host）。管理口端口只从 `<setline port>` 来（配了 `<setline>` 就必须
 * 写它，是配置校验的一部分；命令行不再覆盖），basctl 拨 `127.0.0.1:<port>`（写接口只在管理口上、
 * 且只认回环，见 {@link resolveSetlinePort}）。没配 `<setline>` 就是这份配置没启用 setline，
 * 没有端口可拨，报一句就退出——不替谁猜一个缺省端口。
 *
 * **只推一次、不常驻**：对账的时机是 `start` / `stop`（各跑一次）加手工这一次。setline 自己就是
 * 常驻服务，"什么时候该改路由"这件事由实例的启停说清，不需要第二个轮询进程去猜。
 */
int cmdSetline(string[] args) {
  string confFile;
  foreach (arg; args) {
    if (arg == "--sync")
      continue; // 推一次本来就是缺省动作，留着这个写法给脚本与肌肉记忆
    // 别的 --xxx 一律当写错的开关：端口只有 <setline port> 一处来源，所以这里不再有
    // --endpoint / --output 这类旋钮，踩到就报用法，别把它当配置文件路径去解析。
    else if (arg.startsWith("--")) {
      stderr.writeln("Unknown option: " ~ arg);
      setlineUsage();
      return 1;
    }
    else if (!confFile.length)
      confFile = arg;
    else {
      setlineUsage();
      return 1;
    }
  }

  auto basHome = resolveBasHome();
  if (!confFile.length)
    confFile = buildPath(basHome, "conf", "server.xml");
  if (!exists(confFile)) {
    stderr.writeln("Cannot find config file " ~ confFile);
    return 1;
  }

  auto container = parseServerXmlFile(confFile);
  if (container.setlineHostname.isNull) {
    // 没声明 <setline> 就是这份配置不启用 setline：没有命名空间，也没有管理口端口。
    stderr.writeln("No <setline> in " ~ confFile ~ ": this BAS_HOME does not use setline,"
        ~ " so there is nothing to push. Add <setline port=\"10080\"/> to enable.");
    return 1;
  }
  auto hostname = strip(container.setlineHostname.get);

  ushort port;
  try
    port = resolveSetlinePort(container.setlinePortText());
  catch (Exception e) {
    stderr.writeln(e.msg);
    return 1;
  }

  // 对的是「现状」（servers/<name>/server.info），不是 server.xml：配置改了但实例没重启时路由
  // 不该跟着变，动态端口也只有运行信息里才有。
  auto running = runningPlan(liveInstances(basHome));
  if (running.conflicts.length) {
    printConflicts(running.conflicts);
    return 1;
  }
  return syncRoutesToSetline(running.routes, port, hostname);
}

/** 打印路由冲突并给出修法。 */
private void printConflicts(const(SetlineConflict)[] conflicts) {
  foreach (line; conflictLines(conflicts))
    stderr.writeln(line);
  stderr.writeln("Give each webapp its own <url path=\"...\"/> so no two share a path.");
}

/** `setline` 的用法。 */
private void setlineUsage() {
  stderr.writeln("Usage: basctl setline [server.xml] [--sync]");
  stderr.writeln("  Pushes the routes of the live instances (servers/<name>/server.info) to the");
  stderr.writeln("  running setline: one entry address routes by Host + path prefix to every");
  stderr.writeln("  server's http port. Idempotent - only this BAS_HOME namespace is replaced.");
  stderr.writeln("  One shot only: --sync spells the same action out. The reconcile points are");
  stderr.writeln("  `basctl start` / `stop` (each runs this once); there is no --watch daemon,");
  stderr.writeln("  because the instances' own start/stop already say when routes must change.");
  stderr.writeln("  basctl never writes setline's own config: listen / adminListen belong to the");
  stderr.writeln("  setline service (systemd / container entry), which basctl neither starts nor");
  stderr.writeln("  stops. It only needs to know where to push, and complains when nothing answers.");
  stderr.writeln("  The admin port comes from <setline port=\"...\"/> in server.xml (basctl dials");
  stderr.writeln("  127.0.0.1:<port>, the only address its write API accepts); there is no built-in");
  stderr.writeln("  default and no command line override. A config without <setline> does not use");
  stderr.writeln("  setline at all, so this command has nothing to push.");
  stderr.writeln("  Routes go under the namespace declared by <setline hostname=\"...\"> (default");
  stderr.writeln("  localhost, \"*\" for any Host) so several BAS_HOMEs can share one setline.");
}

/** `BAS_HOME` 有值时取其指向目录，否则取当前工作目录。 */
string resolveBasHome() @trusted {
  import std.file : getcwd;

  auto fromEnv = strip(environment.get("BAS_HOME", ""));
  if (fromEnv.length)
    return absolutePath(fromEnv);
  return absolutePath(getcwd());
}

/**
 * 取命令行里的配置文件：第一个位置参数以 `.xml` 结尾即视为 `server.xml`（`<pattern>` 是
 * farm 名 / `farm.server` / `all`，不会以 `.xml` 结尾），否则用 `$BAS_HOME/conf/server.xml`。
 * 命中的参数会从 `rest` 摘掉，剩下的就是 `<pattern>` 与选项，所以选项写在前面或后面都行。
 */
private string takeConfigFile(ref string[] rest) {
  if (rest.length && !rest[0].startsWith("-") && rest[0].endsWith(".xml")) {
    auto value = rest[0];
    rest = rest[1 .. $];
    return value;
  }
  return buildPath(resolveBasHome(), "conf", "server.xml");
}

/**
 * `status` 的 setline 一节：首行是命名空间（`server.xml` 的 `<setline hostname>`）、basctl 拨的
 * 管理口地址与它通不通，随后是「路由对没对上账」的 route 列。没配 `<setline>` 返回空数组，
 * `status` 就不打这一节。
 *
 * 入口状态只看「有没有人应答」：setline 是机器级服务，basctl 不知道也不该猜它归谁管（systemd /
 * 容器入口 / 手工），所以不报 pid。route 列读一次 `GET /_setline/routes`（只读、无副作用，本机
 * 来源免凭据），与运行中的实例该有的路由对照——**缺 / 端口对不上 / 多** 各占一行，全对得上就是
 * 一行 `routes in sync (N)`；读不动（来源不在对方的 `peerReaders` 里 / 不是 setline / 连不上）
 * 也各用一行说清，不当成命令失败。
 *
 * 端口来自 `<setline port>`（唯一来源，setline 的**管理口**：写接口只在管理口上，读接口只在
 * `status` 这里拨一次）：有 `<setline>` 就有它（写了非法值在解析 `server.xml` 时就报错，走不到
 * 这里）；没有 `<setline>` 时整节省略，不报缺端口。这里仍兜一层异常，是为了手工构造容器的调用方
 * （`Container` 是公开类型）也能拿到一句说得清的话。
 */
public string[] setlineStatusLines(const Container container, const(ServerInfo)[] live) {
  if (container.setlineHostname.isNull)
    return [];
  auto hostname = strip(container.setlineHostname.get);
  ushort port;
  try
    port = resolveSetlinePort(container.setlinePortText());
  catch (Exception e)
    return [format!"host=%s (%s)"(hostname, e.msg)];

  // 没人听就不拨号：`(down)` 已经说完了，再补一句"连不上"只是重复
  if (portFree(port))
    return [format!"host=%s port=%s (down)"(hostname, port)];

  auto lines = [format!"host=%s port=%s (up)"(hostname, port)];
  auto plan = runningPlan(live);
  if (plan.conflicts.length) {
    // 实例之间就冲突（同一路径被端口集合不同的 webapp 认领）：这时候没有"该有的路由"可对账
    foreach (line; conflictLines(plan.conflicts))
      lines ~= "  " ~ line;
    lines ~= "  routes not reconciled; fix the conflict, then `basctl setline --sync`";
    return lines;
  }

  string json;
  final switch (fetchRouteTable(port, json)) {
  case RouteRead.ok:
    try {
      auto table = parseRouteTable(json);
      lines ~= routeDriftLines(plan.routes,
          hostname in table ? table[hostname] : (int[][string]).init);
    } catch (Exception e) {
      lines ~= "  cannot read routes: " ~ e.msg;
    }
    break;
  case RouteRead.denied:
    // 拨的是本机的管理口，被拒只可能是那台 setline 不认这个来源：要么端口指的是别的机器上的
    // setline，要么本机地址没写在它的 peerReaders 里——basctl 不持有凭据，也不会为一次 status
    // 去配一个。
    lines ~= "  routes: " ~ adminAddress(port)
        ~ " refuses reads from this host (setline allows localhost and its peerReaders list)";
    break;
  case RouteRead.unexpected:
    lines ~= "  routes: " ~ adminAddress(port) ~ " answers HTTP but is not the setline we expect";
    break;
  case RouteRead.unreachable:
    lines ~= "  routes: cannot reach setline at " ~ adminAddress(port);
    break;
  }
  return lines;
}

/**
 * `status`：列出 `$BAS_HOME/servers` 下仍在运行的实例。
 *
 * 有运行信息（`server.info`）的实例按它展示端口、引擎、启动时间与各 webapp 的对外 url——端口是
 * 启动前就定下的，不必再用 `ss` / `netstat` 反查监听端口（Windows 开发机同样可用）。pid 已经
 * 不在的显示成 `stale`，提示信息还在但进程没了；没有运行信息的目录直接忽略。
 */
int cmdStatus() {
  auto basHome = resolveBasHome();
  writeln(banner(basctlVersion, deployedBasVersion(buildPath(basHome, "conf", "server.xml"))));
  stdout.flush();
  auto serversDir = buildPath(basHome, "servers");
  auto container = readContainer(basHome);
  // route 列要拿运行中的实例算"该有的路由"，所以边打印边收集
  ServerInfo[] live;

  if (!exists(serversDir) || !isDir(serversDir)) {
    stderr.writeln("No servers directory: ", serversDir);
    printSetlineStatus(container.isNull ? null : setlineStatusLines(container.get, live));
    return 1;
  }

  string[] names;
  foreach (entry; dirEntries(serversDir, SpanMode.shallow)) {
    if (entry.isDir)
      names ~= baseName(entry.name);
  }
  names.sort();

  string[] lines;
  foreach (name; names) {
    auto info = readInstanceInfo(basHome, name);
    if (info.isNull)
      continue;
    if (info.get.pid <= 0 || !processRunning(info.get.pid)) {
      lines ~= staleStatusLine(info.get, name);
    } else {
      lines ~= statusLines(info.get);
      live ~= info.get;
    }
  }

  if (lines.length) {
    writeln("---------------running servers---------------");
    foreach (line; lines)
      writeln(line);
  }
  printSetlineStatus(container.isNull ? null : setlineStatusLines(container.get, live));
  return 0;
}

/** 打印 setline 那一节（未配置 `<setline>` 时什么都不打）。 */
private void printSetlineStatus(string[] lines) {
  if (!lines.length)
    return;
  writeln("---------------setline---------------");
  foreach (line; lines)
    writeln(line);
}

/**
 * 一个运行中实例的展示行：首行是标识（pid / 端口 / 引擎 / 启动时间），随后每个 webapp 一行
 * `<context>  <uri>`；声明了对外 url 的再补 `urls=...`，便于一眼看出这个 webapp 从哪些路径
 * 对外服务（未声明时按 context 对外）。
 */
public string[] statusLines(const ServerInfo info) {
  string[] lines;
  auto engine = info.engine.length ? " engine=" ~ info.engine : "";
  auto started = info.started.length ? " started=" ~ info.started : "";
  lines ~= format!"%s(pid=%s port=%s%s%s)"(info.id, info.pid, info.httpPort, engine, started);

  size_t width;
  foreach (app; info.webapps) {
    if (app.context.length > width)
      width = app.context.length;
  }
  foreach (app; info.webapps) {
    auto urls = app.urls.length ? "  urls=" ~ app.urls.join(",") : "";
    lines ~= format!"  %s  %s%s"(leftJustify(app.context, width), app.uri, urls);
  }
  return lines;
}

/** 有运行信息但进程已不在的实例：信息还在，说明它是崩溃或被 `kill -9` 留下的。 */
public string staleStatusLine(const ServerInfo info, string name) {
  auto pid = info.pid > 0 ? " pid=" ~ info.pid.to!string : "";
  return format!"%s(stale%s port=%s)"(info.id.length ? info.id : name, pid, info.httpPort);
}
