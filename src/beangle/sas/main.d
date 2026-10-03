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

module beangle.sas.main;

import std.algorithm : canFind, sort;
import std.conv : text, to;
import std.exception : enforce;
import std.file : DirEntry, SpanMode, dirEntries, exists, isDir, readText;
import std.format : format;
import std.path : absolutePath, baseName, buildPath;
import std.process : Config, execute, environment;
import std.regex : matchFirst, regex;
import std.stdio : stderr, stdout, writeln;
import std.string : indexOf, join, lastIndexOf, split, strip;

/** Keep in sync with `dub.json` / package release version. */
enum sasCliVersion = "0.0.1";

version (unittest) {
} else {
  void main(string[] args) {
    if (args.length < 2) {
      printUsage();
      return;
    }
    switch (args[1]) {
    case "status":
      cmdStatus();
      break;
    default:
      stderr.writeln("Unknown command: ", args[1]);
      printUsage();
      break;
    }
  }
}

private:

void printUsage() {
  stderr.writeln("Usage: sasctl <command>");
  stderr.writeln("Commands:");
  stderr.writeln("  status   Show running servers (pid, listen ports) under SAS_HOME/servers");
}

/** ASCII logo from Scala `org.beangle.sas.Version.logo` (Graffiti-style lines). */
string sasLogo(string version_) {
  return text(
i` ___    __    ___
/ __)  /__\  / __)
\__ \ /(__)\ \__ \
(___/(__)(__)(___/
version $(version_)`);
}

/** Uses `SAS_HOME` when set; otherwise the current working directory. */
string resolveSasHome() @trusted {
  import std.file : getcwd;

  auto fromEnv = strip(environment.get("SAS_HOME", ""));
  if (fromEnv.length)
    return absolutePath(fromEnv);
  return absolutePath(getcwd());
}

void cmdStatus() {
  writeln(sasLogo(sasCliVersion));
  stdout.flush();
  runStatus();
}

void runStatus() {
  immutable sasHome = resolveSasHome();
  immutable serversDir = buildPath(sasHome, "servers");

  if (!exists(serversDir) || !isDir(serversDir)) {
    stderr.writeln("No servers directory: ", serversDir);
    return;
  }

  string[] names;
  foreach (DirEntry de; dirEntries(serversDir, SpanMode.shallow)) {
    if (de.isDir)
      names ~= baseName(de.name);
  }
  names.sort();

  immutable listenSnapshot = readListenSnapshot();
  int shown;

  foreach (dirName; names) {
    immutable pidPath = buildPath(serversDir, dirName, "SERVER_PID");
    if (!exists(pidPath))
      continue;
    immutable pidStr = strip(readText(pidPath));
    if (!pidStr.length)
      continue;
    int pid;
    try
      pid = pidStr.to!int;
    catch (Exception) {
      stderr.writeln(dirName, ": invalid SERVER_PID content");
      continue;
    }
    if (!processRunningOs(pid))
      continue;

    auto ports = portsForPidOs(listenSnapshot, pid);
    if (!shown) {
      writeln("---------------running servers---------------");
      shown = 1;
    }
    writeln(format!"%s(pid=%s port=%s)"(dirName, pid, ports.length ? ports.join(",") : "?"));
  }
}

/** Snapshot of TCP listeners: `ss -tlnp` on POSIX, `netstat -ano` on Windows. */
string readListenSnapshot() @trusted {
  version (Windows) {
    auto res = execute(["netstat", "-ano", "-p", "tcp"], null, Config.stderrPassThrough);
    if (res.status != 0)
      res = execute(["netstat", "-ano"], null, Config.stderrPassThrough);
    if (res.status != 0)
      return "";
    return cast(string) res.output;
  } else version (Posix) {
    auto res = execute(["ss", "-tlnp"], null, Config.stderrPassThrough);
    if (res.status != 0)
      return "";
    return cast(string) res.output;
  } else {
    return "";
  }
}

bool processRunningOs(int pid) @trusted {
  version (Windows) {
    import core.sys.windows.windows;

    if (pid <= 0)
      return false;
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, cast(DWORD) pid);
    if (h is null)
      return false;
    CloseHandle(h);
    return true;
  } else version (Posix) {
    import core.stdc.errno : errno, EPERM, ESRCH;
    import core.sys.posix.signal : kill;

    if (pid <= 0)
      return false;
    errno = 0;
    if (kill(pid, 0) == 0)
      return true;
    if (errno == EPERM)
      return true;
    return errno != ESRCH;
  } else {
    return false;
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
private string[] portsFromSs(string ssOutput, int pid) {
  auto rePid = regex(format!`pid=%s(,|\))`(pid));
  string[] ports;
  foreach (line; ssOutput.split('\n')) {
    auto stripped = strip(line);
    if (!stripped.length || stripped.canFind("State"))
      continue;
    if (!matchFirst(stripped, rePid).empty) {
      immutable local = extractLocalAddressBeforeUsers(stripped);
      if (!local.length)
        continue;
      try {
        immutable p = extractListenPort(local);
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
 * Non-English Windows locales may use a different state label; use English netstat or rely on ss-equivalent tooling then.
 */
private string[] portsFromNetstat(string netstatOutput, int pid) {
  auto reLine = regex(`^\s*TCP\s+(\S+)\s+\S+\s+LISTENING\s+(\d+)\s*$`);
  string[] ports;
  immutable pidStr = pid.to!string;
  foreach (line; netstatOutput.split('\n')) {
    auto m = matchFirst(strip(line), reLine);
    if (m.empty)
      continue;
    if (m[2] != pidStr)
      continue;
    try {
      immutable p = extractListenPort(m[1]);
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
private string extractLocalAddressBeforeUsers(string line) {
  enum marker = "users:(";
  auto idx = indexOf(line, marker);
  if (idx < 0)
    return "";
  auto left = strip(line[0 .. idx]);
  auto parts = split(left);
  if (parts.length < 2)
    return "";
  return parts[$ - 2];
}

/** Port segment from `host:port` or `[ipv6]:port`. */
private string extractListenPort(string localAddrPort) {
  auto bracketClose = lastIndexOf(localAddrPort, ']');
  if (bracketClose >= 0) {
    immutable tail = localAddrPort[bracketClose + 1 .. $];
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
  immutable sample = "tcp LISTEN 0 128 127.0.0.1:9090 0.0.0.0:* users:((\"java\",pid=4242,fd=99))";
  auto ports = portsFromSs(sample ~ "\n", 4242);
  assert(ports == ["9090"]);
}

@("portsFromNetstat English LISTENING") unittest {
  immutable sample = "  TCP    127.0.0.1:8088         0.0.0.0:0              LISTENING       805964\r";
  auto ports = portsFromNetstat(sample ~ "\n", 805964);
  assert(ports == ["8088"]);
}
