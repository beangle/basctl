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
 * 实例进程存活判断、身份核对、信号发送与日志滚动。
 */
module bas.serverstatus;

import bas.config : Server;

import std.algorithm : canFind, splitter;
import std.string : startsWith;
import std.conv : to;
import std.array : split;
import std.datetime.systime : Clock;
import std.file;
import std.format : format;
import std.path : buildPath;

/** 判断 pid 对应的进程是否存活（POSIX `kill(pid,0)` / Windows `OpenProcess`）。 */
bool processRunning(int pid) @trusted {
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
    import core.stdc.errno : EPERM, ESRCH, errno;
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

/**
 * pid 的命令行是否确实是实例 `instance` 的进程。
 *
 * 运行信息里只记 pid，而 pid 会被系统回收：实例被 `kill -9` 之后再起别的进程，同一个 pid 可能
 * 落到别人头上，照 pid 发信号就会伤及无辜。Linux 上核对 `/proc/<pid>/cmdline` 里的
 * `-Dbas.server=<instance>`——basctl 生成 spec 时必带的 JVM 参数，正好是实例身份。
 *
 * 命令过长时 creator 会把参数折成 java 参数文件（`java @<file>`，见 `docs/engine-creator.md`），
 * 此时 cmdline 里看不到 `-D` 参数，所以还要跟进这些 `@file` 的内容。
 *
 * 判定不了时（非 Linux、读不到 cmdline）返回 true：宁可放过，也不因为平台差异拦住正常停止；
 * 要绝对确认用 `basctl stop --force`（不做身份核对，直接 SIGKILL）。
 */
bool pidLooksLikeInstance(int pid, string instance) @trusted {
  version (linux) {
    import std.file : exists, isFile, readText;

    if (pid <= 0 || !instance.length)
      return false;
    string cmdline;
    try
      cmdline = readText("/proc/" ~ pid.to!string ~ "/cmdline");
    catch (Exception)
      return true;
    auto marker = "-Dbas.server=" ~ instance;
    foreach (arg; cmdline.split('\0')) {
      if (arg == marker)
        return true;
      // java 参数文件：内容里每行一个参数，`-Dbas.server=` 就在其中
      if (arg.startsWith("@")) {
        auto file = arg[1 .. $];
        try {
          if (exists(file) && isFile(file) && readText(file).splitter("\n").canFind(marker))
            return true;
        } catch (Exception) {
          // 读不到参数文件就只按 cmdline 判断
        }
      }
    }
    return false;
  } else {
    return true;
  }
}

/** 给进程发信号：`force` 为真发 SIGKILL，否则 SIGTERM；返回是否成功。 */
bool signalProcess(int pid, bool force) @trusted {
  version (Windows) {
    import std.process : Config, execute;

    auto res = execute(["taskkill", "/PID", pid.to!string, force ? "/F" : "/T"], null, Config.none);
    return res.status == 0;
  } else {
    import core.sys.posix.signal : SIGKILL, SIGTERM, kill;

    return kill(pid, force ? SIGKILL : SIGTERM) == 0;
  }
}

/**
 * 滚动 `servers/<name>/logs/console.out` 到 `logs/archive/<name>-yyyyMMdd.out`，
 * 然后重建空的 console.out。
 */
void rollLog(string basHome, Server server) {
  auto serverHome = buildPath(basHome, "servers", server.qualifiedName);
  auto consoleOut = buildPath(serverHome, "logs", "console.out");
  if (exists(consoleOut)) {
    auto now = Clock.currTime();
    auto archiveDir = buildPath(basHome, "logs", "archive");
    mkdirRecurse(archiveDir);
    auto archive = buildPath(archiveDir, format!"%s-%04d%02d%02d.out"(
        server.qualifiedName, now.year, now.month, now.day));
    if (exists(archive))
      append(archive, read(consoleOut));
    else
      rename(consoleOut, archive);
  }
  mkdirRecurse(buildPath(serverHome, "logs"));
  write(consoleOut, "");
}
