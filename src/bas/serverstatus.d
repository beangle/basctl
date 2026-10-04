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
 * 实例进程存活判断与日志滚动。
 */
module bas.serverstatus;

import bas.config : Server;

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
 * 滚动 `servers/<name>/logs/console.out` 到 `logs/archive/<name>-yyyyMMdd.out`，
 * 然后重建空的 console.out。
 */
void rollLog(string sasHome, Server server) {
  auto serverHome = buildPath(sasHome, "servers", server.qualifiedName);
  auto consoleOut = buildPath(serverHome, "logs", "console.out");
  if (exists(consoleOut)) {
    auto now = Clock.currTime();
    auto archiveDir = buildPath(sasHome, "logs", "archive");
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
