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

/** Unit tests for bas.serverstatus. */
module test.serverstatus_test;

import bas.serverstatus;

import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.process : spawnProcess, thisProcessID, wait;
import std.uuid : randomUUID;

@("pidLooksLikeInstance leaves processes without the marker alone") unittest {
  assert(!pidLooksLikeInstance(thisProcessID, "no-such-instance-marker"));
  assert(!pidLooksLikeInstance(0, "any"));
}

@("pidLooksLikeInstance follows the java argfile the creator writes") unittest {
  // 命令过长时 creator 把参数折成 `java @<file>`：cmdline 里只剩 `@file`，
  // `-Dbas.server=` 在文件里，不跟进文件就认不出自己的实例（stop 会拒绝停）。
  auto dir = buildPath(tempDir, "basctl-serverstatus-" ~ randomUUID().toString());
  mkdirRecurse(dir);
  scope (exit) rmdirRecurse(dir);
  auto argFile = buildPath(dir, "engine-entry.argv.args");
  write(argFile, "-server\n-Xmx256m\n-Dbas.server=f.s1\n-cp\n/somewhere.jar\n");

  // sh 只看 -c 的脚本，`@file` 只是 argv 里的一个参数——正好模拟 `java @file` 的 cmdline
  // （脚本里带上 `; :`，否则 shell 可能直接 exec 掉 sleep，把 `@file` 参数一起丢掉）
  auto child = spawnProcess(["/bin/sh", "-c", "sleep 30; :", "@" ~ argFile]);
  auto pid = child.processID;
  scope (exit) {
    signalProcess(pid, true);
    child.wait();
  }

  assert(pidLooksLikeInstance(pid, "f.s1"));
  assert(!pidLooksLikeInstance(pid, "other.server"));
}
