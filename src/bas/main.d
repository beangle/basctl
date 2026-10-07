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
 * `start` / `stop` / `run` / `setline` / `firewall` / `pull`。
 */
module bas.main;

import bas.banner;
import bas.config;
import bas.embed : defaultBasVersion, runEmbedded;
import bas.enginecreator;
import bas.firewall;
import bas.init;
import bas.net;
import bas.pull;
import bas.resolver;
import bas.serverinfo : ServerInfo, readInstanceInfo;
import bas.serverstatus;
import bas.setline;
import bas.setlineproc;
import bas.starter;

import std.algorithm : canFind, sort;
import std.conv : to;
import std.file : SpanMode, dirEntries, exists, isDir, mkdirRecurse, readText, write;
import std.format : format;
import std.json : JSONType, parseJSON;
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
  stderr.writeln("                                <server http=\"0\">: basctl picks and records the port)");
  stderr.writeln("  stop [server.xml] <pattern>   Stop the instances started by `start` (pid from server.info)");
  stderr.writeln("                                (--timeout=<sec> default 15, --force: SIGKILL at once)");
  stderr.writeln("  run [options] <app>           Run one webapp in embedded mode");
  stderr.writeln("                                (--engine=<type>-<version>, e.g. tomcat-11.0.25;");
  stderr.writeln("                                bas engine version defaults to " ~ defaultBasVersion ~ ")");
  stderr.writeln("  setline [server.xml]          Render the setline config for the whole topology:");
  stderr.writeln("                                one entry address routes to every server's http port");
  stderr.writeln("                                (writes conf/setline.json; --output=<file>)");
  stderr.writeln("                                (--listen=<addr>)");
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
 * `setline [server.xml] [--output=<file>] [--listen=<addr>] [--sync] [--stop] [--force]`：
 * 把 server.xml 的
 * 服务拓扑渲染成 setline（本地 HTTP 路径路由器）的 JSON 配置——一个入口地址按路径前缀把请求
 * 转发到各 server 的 http 端口，同一 webapp 的多个实例自动成为端口列表。
 *
 * 路径取自 webapp 的 `<url path>`（未声明时退回 context path）。同一路径被端口集合不同的多个
 * webapp 认领时无法判定归属，打印冲突并退出，不写出配置。
 *
 * 缺省 server.xml 取 `$BAS_HOME/conf/server.xml`，结果写到 `$BAS_HOME/conf/setline.json`，入口
 * 取 `--listen` > `<setline listen>` > `127.0.0.1:8080`，路由落在 setline 的兜底命名空间 `*`
 * （server.xml 没有 hostname，无法按域名分组）。写完把结果位置、路由条数与入口地址打出来；
 * `--output=-` 时只写 stdout（便于取片段并入全局代理）。
 *
 * 两个子模式：
 *  - `--sync`：确保入口可用（在跑就复用，空闲就地启动），再把整组路由推给 setline；
 *  - `--stop [--force]`：只停 basctl 就地启动的那个（`$BAS_HOME/run/setline.pid`），
 *    进程不退时加 `--force` 才 SIGKILL。
 */
int cmdSetline(string[] args) {
  string confFile;
  string outFile;
  string listen;
  bool sync, stop, force;
  foreach (arg; args) {
    if (arg.startsWith("--listen="))
      listen = arg["--listen=".length .. $];
    else if (arg.startsWith("--output="))
      outFile = arg["--output=".length .. $];
    else if (arg == "--sync")
      sync = true;
    else if (arg == "--stop")
      stop = true;
    else if (arg == "--force")
      force = true;
    else if (!confFile.length)
      confFile = arg;
    else {
      setlineUsage();
      return 1;
    }
  }

  auto basHome = resolveBasHome();
  if (stop) {
    // bas.sh 总会把 conf/server.xml 当第一个参数传进来；--stop 不需要它，忽略即可
    if (sync || outFile.length) {
      setlineUsage();
      return 1;
    }
    return stopSetline(basHome, force);
  }
  if (sync && outFile.length) {
    stderr.writeln("--sync pushes routes to the running setline; it does not use --output.");
    return 1;
  }

  if (!confFile.length)
    confFile = buildPath(basHome, "conf", "server.xml");
  if (!exists(confFile)) {
    stderr.writeln("Cannot find config file " ~ confFile);
    return 1;
  }

  auto container = parseServerXmlFile(confFile);
  if (!listen.length)
    listen = container.setlineListen.isNull ? defaultSetlineListen : strip(container.setlineListen.get);

  auto plan = setlinePlan(container);
  if (plan.conflicts.length) {
    foreach (c; plan.conflicts)
      stderr.writeln("Route conflict on " ~ c.path ~ ": declared by " ~ c.webapps.join(", "));
    stderr.writeln("Give each webapp its own <url path=\"...\"/> so no two share a path.");
    return 1;
  }
  auto routes = plan.routes;

  if (sync)
    return syncSetlineRoutes(basHome, routes, listen);

  auto text = renderSetlineConfig(routes, listen);
  if (outFile == "-") {
    stdout.write(text);
    stdout.flush();
    stderr.writeln(format!"%s routes, entry http://%s"(routes.length, listen));
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
  writeln(format!"%s routes, entry http://%s"(routes.length, listen));
  writeln("run: setline -f " ~ target);
  return 0;
}

/**
 * `--sync`：先要一份 `conf/setline.json`（就地启动要用它；不存在才写骨架，已有的一律不改——
 * 那是 setline 进程的配置，里面有 `adminToken` 这类 basctl 不该碰的东西），再确保入口可用
 * （在跑就复用，空闲就地启动），最后把整组路由推过去。路由由 setline 自己写回文件，重启不丢。
 */
private int syncSetlineRoutes(string basHome, const(SetlineRoute)[] routes, string listen) {
  ListenEndpoint endpoint;
  try
    endpoint = parseListenEndpoint(listen);
  catch (Exception e) {
    stderr.writeln(e.msg);
    return 1;
  }

  auto confFile = buildPath(basHome, "conf", "setline.json");
  if (!exists(confFile)) {
    mkdirRecurse(dirName(confFile));
    try
      write(confFile, renderSetlineConfig(null, listen));
    catch (Exception e) {
      stderr.writeln("Cannot write " ~ confFile ~ ": " ~ e.msg);
      return 1;
    }
  } else {
    auto fileListen = setlineFileListen(confFile);
    bool differs;
    try
      differs = fileListen.length > 0 && parseListenEndpoint(fileListen) != endpoint;
    catch (Exception)
      differs = false;
    if (differs)
      stderr.writeln("Note: " ~ confFile ~ " says listen=" ~ fileListen ~ " but this command uses "
          ~ listen ~ "; the running setline follows the file. The routes below go to " ~ listen ~ ".");
  }

  if (syncSetline(basHome, endpoint, renderRouteMap(routes)) != 0)
    return 1;
  writeln(format!"%s routes synced to http://%s"(routes.length, endpoint.toString()));
  return 0;
}

/** 读 `conf/setline.json` 里 `listen` 的原始写法；文件或字段不可用时返回空串。 */
public string setlineFileListen(string path) {
  try {
    auto root = parseJSON(readText(path));
    if (!("listen" in root.object))
      return "";
    auto listen = root["listen"];
    if (listen.type == JSONType.string)
      return strip(listen.str);
    if (listen.type == JSONType.integer)
      return listen.integer.to!string;
  }
  catch (Exception) {
  }
  return "";
}

/** `setline` 的用法。 */
private void setlineUsage() {
  stderr.writeln("Usage: basctl setline [server.xml] [--output=<file>] [--listen=<addr>] [--sync]");
  stderr.writeln("       basctl setline --stop [--force]");
  stderr.writeln("  Renders the setline config for the whole topology: one entry address routes");
  stderr.writeln("  by path prefix to every server's http port. Output defaults to conf/setline.json");
  stderr.writeln("  (--output=- writes the JSON to stdout instead; --listen sets the entry address.)");
  stderr.writeln("  --sync pushes the routes to a running setline, starting one if the entry is free;");
  stderr.writeln("  --stop stops the instance basctl started ($BAS_HOME/run/setline.pid), --force SIGKILLs it.");
  stderr.writeln("  Routes go under setline's fallback namespace \"*\": server.xml has no hostname,");
  stderr.writeln("  so the whole topology is a single group matching any Host by path.");
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

  if (!exists(serversDir) || !isDir(serversDir)) {
    stderr.writeln("No servers directory: ", serversDir);
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
  return 0;
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
