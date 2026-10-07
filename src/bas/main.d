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
 * basctl 命令行入口：`version` / `banner` / `status` / `init` / `make` / `resolve` /
 * `start` / `stop` / `run` / `setline` / `doctor` / `firewall` / `pull`。
 *
 * `start` / `stop` 在 `server.xml` 配了 `<setline>` 时还会自动对账路由（见 bas.setlineproc），
 * `--no-setline` 可临时跳过。
 */
module bas.main;

import bas.banner;
import bas.config;
import bas.doctor : runDoctor;
import bas.embed : defaultBasVersion, runEmbedded;
import bas.endpoint : ListenEndpoint, SetlineEndpointChoice, portFree, resolveSetlineEndpoint;
import bas.enginecreator;
import bas.firewall;
import bas.init;
import bas.net;
import bas.pull;
import bas.shellenv : readContainer;
import bas.resolver;
import bas.serverinfo : ServerInfo, liveInstances, readInstanceInfo;
import bas.serverstatus;
import bas.setline : SetlineConflict, conflictLines, renderSetlineConfig, runningPlan, setlinePlan;
import bas.setlineproc;
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
      // 配置与解析类错误（如 <setline> 缺 endpoint）在这里落成一行，
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
  stderr.writeln("  setline [server.xml]          Render the setline config for the whole topology:");
  stderr.writeln("                                one entry address routes to every server's http port");
  stderr.writeln("                                (writes conf/setline.json; --output=<file>)");
  stderr.writeln("                                (routes under <setline hostname>; entry from");
  stderr.writeln("                                 --endpoint > <setline endpoint>, one required;");
  stderr.writeln("                                 --sync/--watch push the live instances' routes)");
  stderr.writeln("  doctor [server.xml]           Check that java / jstart are on this machine");
  stderr.writeln("                                (setline too, but only when <setline> is configured)");
  stderr.writeln("  firewall [workdir]            Configure firewalld ports from conf/server.xml");
  stderr.writeln("  pull [--remote=<url>] [workdir]  Fetch conf/server.xml from the control endpoint");
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
 * `setline [server.xml] [--output=<file>] [--endpoint=<addr>] [--sync] [--watch]`：
 * 把 server.xml 的服务拓扑渲染成 setline（本地 HTTP 路径路由器）的 JSON 配置——一个入口地址按
 * 路径前缀把请求转发到各 server 的 http 端口，同一 webapp 的多个实例自动成为端口列表。
 *
 * 路径取自 webapp 的 `<url path>`（未声明时退回 context path）。同一路径被端口集合不同的多个
 * webapp 认领时无法判定归属，打印冲突并退出，不写出配置。
 *
 * 缺省 server.xml 取 `$BAS_HOME/conf/server.xml`，结果写到 `$BAS_HOME/conf/setline.json`，路由
 * 落在 `<setline hostname>` 命名空间下（缺省 `localhost`，`*` 表示任意 Host）。写完把结果位置、
 * 路由条数与入口地址打出来；`--output=-` 时只写 stdout（便于取片段并入全局代理）。
 *
 * 入口地址取 `--endpoint` > `<setline endpoint>`（配了 `<setline>` 就必须写 endpoint，是配置校验
 * 的一部分；两处都没有才报错）：setline 的进程归 systemd / 容器入口 / 手工负责，basctl 只认
 * 「它在哪」（见 {@link resolveSetlineEndpoint}）。
 *
 * 两个子模式：
 *  - `--sync`：把「现状」的路由整组推给已在跑的 setline（入口没人应答就报错，不就地拉起）；
 *  - `--watch`：常驻做同一件事（缺省每 5 秒），交给 systemd。
 */
int cmdSetline(string[] args) {
  string confFile;
  string outFile;
  string endpointFlag;
  bool sync, watch;
  auto intervalSec = defaultWatchIntervalSec;
  foreach (arg; args) {
    if (arg.startsWith("--endpoint="))
      endpointFlag = arg["--endpoint=".length .. $];
    else if (arg.startsWith("--output="))
      outFile = arg["--output=".length .. $];
    else if (arg == "--sync")
      sync = true;
    else if (arg == "--watch")
      watch = true;
    else if (arg.startsWith("--interval=")) {
      try
        intervalSec = parseWatchInterval(arg["--interval=".length .. $]);
      catch (Exception e) {
        stderr.writeln(e.msg);
        return 1;
      }
    }
    else if (!confFile.length)
      confFile = arg;
    else {
      setlineUsage();
      return 1;
    }
  }

  auto basHome = resolveBasHome();
  if (sync && outFile.length) {
    stderr.writeln("--sync pushes routes to the running setline; it does not use --output.");
    return 1;
  }
  if (watch && outFile.length) {
    stderr.writeln("--watch keeps syncing routes; it does not use --output.");
    return 1;
  }
  if (sync && watch) {
    stderr.writeln("--sync pushes once; --watch keeps pushing. Pick one.");
    return 1;
  }

  if (!confFile.length)
    confFile = buildPath(basHome, "conf", "server.xml");
  if (!exists(confFile)) {
    stderr.writeln("Cannot find config file " ~ confFile);
    return 1;
  }

  auto container = parseServerXmlFile(confFile);
  if (container.setlineHostname.isNull)
    stderr.writeln("Note: no <setline> in " ~ confFile ~ "; using hostname="
        ~ defaultSetlineHostname ~ ".");
  auto hostname = container.setlineHostname.isNull ? defaultSetlineHostname
    : strip(container.setlineHostname.get);

  SetlineEndpointChoice choice;
  try
    choice = resolveSetlineEndpoint(endpointFlag, container.setlineEndpointText());
  catch (Exception e) {
    stderr.writeln(e.msg);
    return 1;
  }
  auto endpoint = choice.endpoint;
  auto entry = endpoint.toString();

  // --sync / --watch 对的是「现状」（servers/<name>/server.info），不是 server.xml：配置改了但
  // 实例没重启时路由不该跟着变，动态端口也只有运行信息里才有。
  if (watch)
    return watchRoutes(basHome, endpoint, hostname, intervalSec);
  if (sync) {
    auto running = runningPlan(liveInstances(basHome));
    if (running.conflicts.length) {
      printConflicts(running.conflicts);
      return 1;
    }
    return syncRoutesToSetline(running.routes, endpoint, hostname);
  }

  auto plan = setlinePlan(container);
  if (plan.conflicts.length) {
    printConflicts(plan.conflicts);
    return 1;
  }
  auto routes = plan.routes;

  auto text = renderSetlineConfig(routes, entry, hostname);
  if (outFile == "-") {
    stdout.write(text);
    stdout.flush();
    stderr.writeln(format!"%s routes, entry http://%s, host=%s"(routes.length, entry, hostname));
    return 0;
  }

  if (!outFile.length)
    outFile = buildPath(basHome, "conf", "setline.json");
  auto target = absolutePath(outFile);
  try
    write(target, text);
  catch (Exception e) {
    // std.file 的错误信息自带路径前缀，去掉避免与我们的提示重复
    auto reason = e.msg;
    if (reason.startsWith(target ~ ": "))
      reason = reason[target.length + 2 .. $];
    stderr.writeln("Cannot write " ~ target ~ ": " ~ reason);
    return 1;
  }
  writeln("write ", target);
  writeln(format!"%s routes, entry http://%s, host=%s"(routes.length, entry, hostname));
  writeln("run: setline -f " ~ target);
  return 0;
}

/** 打印路由冲突并给出修法（渲染与对账共用）。 */
private void printConflicts(const(SetlineConflict)[] conflicts) {
  foreach (line; conflictLines(conflicts))
    stderr.writeln(line);
  stderr.writeln("Give each webapp its own <url path=\"...\"/> so no two share a path.");
}

/** `setline` 的用法。 */
private void setlineUsage() {
  stderr.writeln("Usage: basctl setline [server.xml] [--output=<file>] [--endpoint=<addr>] [--sync]");
  stderr.writeln("       basctl setline [server.xml] --watch [--interval=<sec>]");
  stderr.writeln("  Renders the setline config for the whole topology: one entry address routes");
  stderr.writeln("  by path prefix to every server's http port. Output defaults to conf/setline.json");
  stderr.writeln("  (--output=- writes the JSON to stdout instead).");
  stderr.writeln("  Routes go under the namespace declared by <setline hostname=\"...\"> (default");
  stderr.writeln("  localhost, \"*\" for any Host) so several BAS_HOMEs can share one setline.");
  stderr.writeln("  The entry address comes from --endpoint > <setline endpoint=\"...\">;");
  stderr.writeln("  there is no built-in default, so one of the two is required.");
  stderr.writeln("  setline itself is a machine service (systemd / container entry): basctl neither");
  stderr.writeln("  starts nor stops it, and complains when nothing answers on the entry.");
  stderr.writeln("  --sync pushes the routes of the live instances (servers/<name>/server.info) to");
  stderr.writeln("  the running setline once;");
  stderr.writeln("  --watch keeps doing that (default every " ~ defaultWatchIntervalSec.to!string
      ~ "s) until stopped.");
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
 * `status` 的 setline 行：命名空间（`server.xml` 的 `<setline hostname>`）、入口地址与入口通不通。
 * 没配 `<setline>` 返回空串，`status` 就不打这一节。
 *
 * 只看「入口有没有人应答」：setline 是机器级服务，basctl 不知道也不该猜它归谁管（systemd /
 * 容器入口 / 手工），所以不报 pid；「坐的是不是我们那台 setline」得写一次路由才知道，那是
 * `setline --sync` 的事，`status` 不做带副作用的探测。
 *
 * 地址来自 `<setline endpoint>`：有 `<setline>` 就有它（写了非法值在解析 `server.xml` 时就报错，
 * 走不到这里）；没有 `<setline>` 时整节省略，不报缺地址。这里仍兜一层异常，是为了手工构造容器
 * 的调用方（`Container` 是公开类型）也能拿到一句说得清的话。
 */
public string setlineStatusLine(const Container container) {
  if (container.setlineHostname.isNull)
    return "";
  auto hostname = strip(container.setlineHostname.get);
  ListenEndpoint endpoint;
  try
    endpoint = resolveSetlineEndpoint("", container.setlineEndpointText()).endpoint;
  catch (Exception e)
    return format!"host=%s (%s)"(hostname, e.msg);
  return format!"host=%s endpoint=%s %s"(hostname, endpoint.toString(),
      portFree(endpoint) ? "(down)" : "(up)");
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
  auto setlineLine = container.isNull ? "" : setlineStatusLine(container.get);

  if (!exists(serversDir) || !isDir(serversDir)) {
    stderr.writeln("No servers directory: ", serversDir);
    printSetlineStatus(setlineLine);
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
    if (info.get.pid <= 0 || !processRunning(info.get.pid))
      lines ~= staleStatusLine(info.get, name);
    else
      lines ~= statusLines(info.get);
  }

  if (lines.length) {
    writeln("---------------running servers---------------");
    foreach (line; lines)
      writeln(line);
  }
  printSetlineStatus(setlineLine);
  return 0;
}

/** 打印 setline 那一节（未配置 `<setline>` 时什么都不打）。 */
private void printSetlineStatus(string line) {
  if (!line.length)
    return;
  writeln("---------------setline---------------");
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
