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
 * basctl 命令行入口：`version` / `status` / `make` / `resolve` / `aes` / `firewall`。
 */
module bas.main;

import bas.aes;
import bas.banner;
import bas.config;
import bas.firewall;
import bas.maker;
import bas.net;
import bas.resolver;
import bas.serverstatus;

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
    case "make":
      if (args.length < 4) {
        stderr.writeln("Usage: basctl make /path/to/conf/server.xml <farm|server|all>");
        return 1;
      }
      return runMaker(args[2], args[3]);
    case "resolve":
      return cmdResolve(args[2 .. $]);
    case "aes":
      if (args.length < 4) {
        stderr.writeln("Usage: basctl aes <key> <plain|encoded>");
        return 1;
      }
      return cmdAes(args[2], args[3]);
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
  stderr.writeln("  version                       Show logo and local hosts");
  stderr.writeln("  status                        Show running servers under $SAS_HOME/servers");
  stderr.writeln("  make <server.xml> <pattern>   Resolve webapps and build engines/servers");
  stderr.writeln("  resolve <server.xml> [pattern...]  Resolve webapps only");
  stderr.writeln("  aes <key> <plain|encoded>     AES/ECB/PKCS5 encrypt or decrypt");
  stderr.writeln("  firewall [workdir]            Configure firewalld ports from conf/server.xml");
}

/** `version`：打印 logo 与本机地址。 */
int cmdVersion() {
  writeln(logo(basctlVersion));
  writeln(hostsLine());
  return 0;
}

/** `aes`：值长度为 32 视为密文解密，否则加密并输出十六进制。 */
int cmdAes(string key, string value) {
  auto aes = new Aes(key);
  writeln(value.length == 32 ? aes.decrypt(value) : aes.encrypt(value));
  return 0;
}

/** Resolves webapps of a config file（Scala `Resolver.main`）。 */
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
  auto sasHome = absolutePath(buildPath(configFile, "..", ".."));

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

  auto missing = resolveWebapps(sasHome, container.repository, container.snapshotRepo, webapps);
  return missing.length ? -1 : 0;
}

/** Uses `SAS_HOME` when set; otherwise the current working directory. */
string resolveSasHome() @trusted {
  import std.file : getcwd;

  auto fromEnv = strip(environment.get("SAS_HOME", ""));
  if (fromEnv.length)
    return absolutePath(fromEnv);
  return absolutePath(getcwd());
}

/** `status`：列出 `$SAS_HOME/servers` 下仍在运行的实例及其监听端口。 */
int cmdStatus() {
  writeln(logo(basctlVersion));
  stdout.flush();
  auto sasHome = resolveSasHome();
  auto serversDir = buildPath(sasHome, "servers");

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

/** Snapshot of TCP listeners: `ss -tlnp` on POSIX, `netstat -ano` on Windows. */
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

/** Dispatch to OS-specific listener snapshot parser. */
private string[] portsForPidOs(string snapshot, int pid) {
  version (Windows)
    return portsFromNetstat(snapshot, pid);
  else version (Posix)
    return portsFromSs(snapshot, pid);
  else
    return [];
}

/** Parses `ss -tlnp` output; returns distinct listen ports for `pid`. */
string[] portsFromSs(string ssOutput, int pid) {
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
 * Parses English `netstat -ano` TCP lines (`LISTENING` state).
 * Non-English Windows locales may use a different state label; use English netstat,
 * or rely on ss-equivalent tooling then.
 */
string[] portsFromNetstat(string netstatOutput, int pid) {
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

/** Slice before `users:(` — same idea as `grep PID` on full line. */
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

/** Port segment from `host:port` or `[ipv6]:port`. */
string extractListenPort(string localAddrPort) {
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

@("extractListenPort ipv4 and bracket ipv6") unittest {
  assert(extractListenPort("127.0.0.1:8080") == "8080");
  assert(extractListenPort("[::1]:8443") == "8443");
}

@("portsFromSs finds port field") unittest {
  auto sample = "tcp LISTEN 0 128 127.0.0.1:9090 0.0.0.0:* users:((\"java\",pid=4242,fd=99))";
  auto ports = portsFromSs(sample ~ "\n", 4242);
  assert(ports == ["9090"]);
}

@("portsFromNetstat English LISTENING") unittest {
  auto sample = "  TCP    127.0.0.1:8088         0.0.0.0:0              LISTENING       805964\r";
  auto ports = portsFromNetstat(sample ~ "\n", 805964);
  assert(ports == ["8088"]);
}
