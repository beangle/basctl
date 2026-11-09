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
 * `start` / `stop` / `run` / `doctor` / `firewall`。
 *
 * 只处理本地配置与进程；远端通道、`pull` 与 `report` 属于 `basagent`。
 *
 * `start` / `stop` 只负责本机实例生命周期。
 */
module bas.main;

import bas.banner;
import bas.cli : resolveBasHome, takeConfigFile;
import bas.config;
import bas.doctor : runDoctor;
import bas.embed : defaultBasVersion, runEmbedded;
import bas.enginecreator;
import bas.firewall;
import bas.init;
import bas.logs : runLogs;
import bas.net;
import bas.shellenv : readContainer;
import bas.resolver;
import bas.serverinfo : ServerInfo, liveInstancePid, liveInstances, readInstanceInfo;
import bas.serverstatus;
import bas.starter;
import bas.versioninfo : basctlVersion;

import std.algorithm : canFind, sort;
import std.conv : to;
import std.file : SpanMode, dirEntries, exists, isDir, mkdirRecurse, readText, write;
import std.format : format;
import std.path : absolutePath, baseName, buildPath, dirName;
import std.stdio : stderr, stdout, writeln;
import std.string : join, leftJustify, startsWith, strip;

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
    case "doctor": {
      auto rest = args[2 .. $];
      return runDoctor(takeConfigFile(rest));
    }
    case "firewall":
      return runFirewall(args[1 .. $]);
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
  stderr.writeln("  init [--force] [workdir]      Install control scripts and a conf/basctl.env template");
  stderr.writeln("  make [server.xml] <pattern>   Generate specs and resolve dependencies (no start)");
  stderr.writeln("  make <type> [options]         Prepare a container for jstart `[engine] init` (creator)");
  stderr.writeln("  resolve <server.xml> [pattern...]  Resolve webapps only");
  stderr.writeln("  start [server.xml] <pattern>  Allocate ports, generate a jstart spec per server and start it");
  stderr.writeln("                                (--port-range=<from>-<to>, default 20000-29999, when");
  stderr.writeln("                                <server http=\"0\">: basctl picks and records the port;");
  stderr.writeln("  stop [server.xml] <pattern>   Stop the instances started by `start` (pid from server.info)");
  stderr.writeln("                                (--timeout=<sec> default 15, --force: SIGKILL at once;");
  stderr.writeln("  run [options] <app>           Run one webapp in embedded mode");
  stderr.writeln("                                (--engine=<type>-<version>, e.g. tomcat-11.0.25;");
  stderr.writeln("                                bas engine version defaults to " ~ defaultBasVersion ~ ")");
  stderr.writeln("  doctor [server.xml]           Check java (required) and jstart (optional)");
  stderr.writeln("  firewall [workdir]            Configure firewalld ports from conf/server.xml");
}

/**
 * `make`：两种输入，同一种「准备」语义——
 *
 *  - `make <tomcat-server|tomcat|undertow|jetty|native> [协议参数]`：jstart `[engine] init`
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
  stderr.writeln("Usage: basctl make <tomcat-server|tomcat|undertow|jetty|native> [options]");
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
 * `status`：列出 `$BAS_HOME/servers` 下仍在运行的实例。
 *
 * 有运行信息（`server.info`）的实例按它展示端口、引擎、启动时间与各 webapp 的对外 url——端口是
 * 启动前就定下的，不必再用 `ss` / `netstat` 反查监听端口（Windows 开发机同样可用）。记录 pid
 * 不在时按命令行找回本实例再展示；找不到就不出现（不再打印 stale 行）；没有运行信息的目录直接忽略。
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
    // 记录 pid 失效但命令行仍能匹配到本实例时，按真实进程展示；真的不在了就不出现在 running 一节。
    auto livePid = liveInstancePid(basHome, name);
    if (livePid.isNull)
      continue;
    info.get.pid = livePid.get;
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
 * 一个运行中实例的展示行：首行是标识（pid / 端口），随后每个 webapp 一行
 * `<context>  <uri>`；声明了对外 url 的再补 `urls=...`，便于一眼看出这个 webapp 从哪些路径
 * 对外服务（未声明时按 context 对外）。引擎与启动时间只存在 `server.info` 里，不占首行的位置。
 */
public string[] statusLines(const ServerInfo info) {
  string[] lines;
  lines ~= format!"%s(pid=%s port=%s)"(info.id, info.pid, info.httpPort);

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

