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
 * basctl 命令行入口：`version` / `status` / `init` / `make` / `resolve` / `start` /
 * `stop` / `run` / `firewall` / `pull`。
 */
module bas.main;

import bas.banner;
import bas.config;
import bas.embed : runEmbedded;
import bas.enginecreator;
import bas.firewall;
import bas.init;
import bas.net;
import bas.pull;
import bas.resolver;
import bas.serverstatus;
import bas.starter;

import std.algorithm : canFind, sort;
import std.conv : to;
import std.exception : enforce;
import std.file : SpanMode, dirEntries, exists, isDir, readText;
import std.format : format;
import std.path : absolutePath, baseName, buildPath;
import std.process : Config, environment, execute;
import std.regex : matchFirst, regex;
import std.stdio : stderr, stdout, writeln;
import std.string : indexOf, join, lastIndexOf, split, strip;

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
    case "status":
      return cmdStatus();
    case "init":
      return runInit(args[2 .. $]);
    case "make":
      return cmdMake(args[2 .. $]);
    case "resolve":
      return cmdResolve(args[2 .. $]);
    case "start":
      if (args.length == 3)
        return runStart(buildPath(resolveSasHome(), "conf", "server.xml"), args[2]);
      if (args.length >= 4)
        return runStart(args[2], args[3]);
      stderr.writeln("Usage: basctl start [server.xml] <farm|server|all>");
      return 1;
    case "stop":
      if (args.length == 3)
        return runStop(buildPath(resolveSasHome(), "conf", "server.xml"), args[2 .. $]);
      if (args.length >= 4)
        return runStop(args[2], args[3 .. $]);
      stderr.writeln("Usage: basctl stop [server.xml] <farm|server|all> [--force] [--timeout=<sec>]");
      return 1;
    case "run":
      return runEmbedded(args[2 .. $]);
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
  stderr.writeln("  version                       Show logo and local hosts");
  stderr.writeln("  status                        Show running servers under $BAS_HOME/servers");
  stderr.writeln("  init [--force] [workdir]      Install the control scripts under <workdir>/bin");
  stderr.writeln("  make [server.xml] <pattern>   Generate specs and resolve dependencies (no start)");
  stderr.writeln("  make <type> [options]         Prepare a container for jstart `[engine] init` (creator)");
  stderr.writeln("  resolve <server.xml> [pattern...]  Resolve webapps only");
  stderr.writeln("  start [server.xml] <pattern>  Generate a jstart spec per server and start it");
  stderr.writeln("  stop [server.xml] <pattern>   Stop the jstart instances started by `start`");
  stderr.writeln("  run [options] <app>           Run a single webapp (war/gav/url) in embedded mode");
  stderr.writeln("  firewall [workdir]            Configure firewalld ports from conf/server.xml");
  stderr.writeln("  pull [--remote=<url>] [workdir]  Fetch conf/server.xml from the control endpoint");
}

/**
 * `make`：两种输入，同一种「准备」语义——
 *
 *  - `make <tomcat-dist|tomcat-embed|undertow-embed> [协议参数]`：jstart `[engine] init`
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
    return runMake(buildPath(resolveSasHome(), "conf", "server.xml"), args[0]);
  if (args.length == 2)
    return runMake(args[0], args[1]);
  makeUsage();
  return 1;
}

/** `make` 的用法（creator 模式与只准备模式）。 */
private void makeUsage() {
  stderr.writeln("Usage: basctl make <tomcat-dist|tomcat-embed|undertow-embed> [options]");
  stderr.writeln("       basctl make [server.xml] <farm|server|all>");
  stderr.writeln("  <type> mode is the jstart `[engine] init` callback; the <pattern> mode only");
  stderr.writeln("  generates specs and resolves dependencies, start them with `basctl start`.");
}

/** `version`：打印 logo 与本机地址。 */
int cmdVersion() {
  writeln(logo(basctlVersion));
  writeln(hostsLine());
  return 0;
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

/** `BAS_HOME` 有值时取其指向目录，否则取当前工作目录。 */
string resolveSasHome() @trusted {
  import std.file : getcwd;

  auto fromEnv = strip(environment.get("BAS_HOME", ""));
  if (fromEnv.length)
    return absolutePath(fromEnv);
  return absolutePath(getcwd());
}

/** `status`：列出 `$BAS_HOME/servers` 下仍在运行的实例及其监听端口。 */
int cmdStatus() {
  writeln(logo(basctlVersion));
  stdout.flush();
  auto basHome = resolveSasHome();
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

  auto listenSnapshot = readListenSnapshot();
  int shown;

  foreach (dirName; names) {
    auto pidPath = buildPath(serversDir, dirName, "SERVER_PID");
    if (!exists(pidPath))
      continue;
    auto pidStr = strip(readText(pidPath));
    if (!pidStr.length)
      continue;
    int pid;
    try
      pid = pidStr.to!int;
    catch (Exception) {
      stderr.writeln(dirName, ": invalid SERVER_PID content");
      continue;
    }
    if (!processRunning(pid))
      continue;

    auto ports = portsForPidOs(listenSnapshot, pid);
    if (!shown) {
      writeln("---------------running servers---------------");
      shown = 1;
    }
    writeln(format!"%s(pid=%s port=%s)"(dirName, pid, ports.length ? ports.join(",") : "?"));
  }
  return 0;
}

/** TCP 监听端口快照：POSIX 用 `ss -tlnp`，Windows 用 `netstat -ano`。 */
string readListenSnapshot() @trusted {
  version (Windows) {
    auto res = execute(["netstat", "-ano", "-p", "tcp"], null, Config.stderrPassThrough);
    if (res.status != 0)
      res = execute(["netstat", "-ano"], null, Config.stderrPassThrough);
    if (res.status != 0)
      return "";
    return res.output;
  } else version (Posix) {
    auto res = execute(["ss", "-tlnp"], null, Config.stderrPassThrough);
    if (res.status != 0)
      return "";
    return res.output;
  } else {
    return "";
  }
}

/** 按操作系统分派到对应的监听端口解析函数。 */
private string[] portsForPidOs(string snapshot, int pid) {
  version (Windows)
    return portsFromNetstat(snapshot, pid);
  else version (Posix)
    return portsFromSs(snapshot, pid);
  else
    return [];
}

/** 解析 `ss -tlnp` 输出，返回 `pid` 的监听端口（去重）。 */
public string[] portsFromSs(string ssOutput, int pid) {
  auto rePid = regex(format!`pid=%s(,|\))`(pid));
  string[] ports;
  foreach (line; ssOutput.split('\n')) {
    auto stripped = strip(line);
    if (!stripped.length || stripped.canFind("State"))
      continue;
    if (!matchFirst(stripped, rePid).empty) {
      auto local = extractLocalAddressBeforeUsers(stripped);
      if (!local.length)
        continue;
      try {
        auto p = extractListenPort(local);
        bool dup;
        foreach (ex; ports) {
          if (ex == p) {
            dup = true;
            break;
          }
        }
        if (!dup)
          ports ~= p;
      } catch (Exception) {
        continue;
      }
    }
  }
  ports.sort();
  return ports;
}

/**
 * 解析英文 `netstat -ano` 的 TCP 行（状态为 `LISTENING`）。
 * 非英文 Windows 区域的状态名不同，需用英文 netstat，或改用 ss 等价工具。
 */
public string[] portsFromNetstat(string netstatOutput, int pid) {
  auto reLine = regex(`^\s*TCP\s+(\S+)\s+\S+\s+LISTENING\s+(\d+)\s*$`);
  string[] ports;
  auto pidStr = pid.to!string;
  foreach (line; netstatOutput.split('\n')) {
    auto m = matchFirst(strip(line), reLine);
    if (m.empty)
      continue;
    if (m[2] != pidStr)
      continue;
    try {
      auto p = extractListenPort(m[1]);
      bool dup;
      foreach (ex; ports) {
        if (ex == p) {
          dup = true;
          break;
        }
      }
      if (!dup)
        ports ~= p;
    } catch (Exception) {
      continue;
    }
  }
  ports.sort();
  return ports;
}

/** 截取 `users:(` 之前的部分，等价于在整行上 grep 出 PID。 */
string extractLocalAddressBeforeUsers(string line) {
  enum marker = "users:(";
  auto idx = line.indexOf(marker);
  if (idx < 0)
    return "";
  auto left = strip(line[0 .. idx]);
  auto parts = left.split();
  if (parts.length < 2)
    return "";
  return parts[$ - 2];
}

/** 从 `host:port` 或 `[ipv6]:port` 中取出端口段。 */
public string extractListenPort(string localAddrPort) {
  auto bracketClose = lastIndexOf(localAddrPort, ']');
  if (bracketClose >= 0) {
    auto tail = localAddrPort[bracketClose + 1 .. $];
    enforce(tail.length >= 2 && tail[0] == ':');
    return strip(tail[1 .. $]);
  }
  auto colon = lastIndexOf(localAddrPort, ':');
  enforce(colon > 0 && colon + 1 < localAddrPort.length);
  return strip(localAddrPort[colon + 1 .. $]);
}
