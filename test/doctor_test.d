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

/** Unit tests for bas.doctor. */
module test.doctor_test;

import bas.doctor;
import bas.jstart : jstartEnvVar;

import std.algorithm : canFind;
import std.array : join;
import std.conv : to;
import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.string : replace, split;
import std.uuid : randomUUID;

/** PATH 上放一个假 jstart，测试里用不到真实命令。 */
private string fakeToolsDir() {
  auto dir = buildPath(tempDir, "basctl-doctor-" ~ randomUUID().toString());
  mkdirRecurse(dir);
  write(buildPath(dir, "jstart"), "#!/bin/sh\n");
  return dir;
}

@("doctor requires java and reports optional jstart") unittest {
  auto dir = fakeToolsDir();
  scope (exit) rmdirRecurse(dir);
  auto env = ToolEnv("", dir, "");

  // 一份最小可解析的 server.xml
  auto base = `<bas version="0.14.0">
  <engines><engine name="e" type="tomcat" version="11"/></engines>
  <farms><farm name="f" engine="e"><server name="s1" http="9980"/></farm></farms>
</bas>`;
  auto confFile = buildPath(dir, "server.xml");
  write(confFile, base);

  auto checks = checkTools(confFile, env);
  assert(checks.length == 2);
  assert(checks[0].name == "java" && checks[0].state == CheckState.missing);
  assert(checks[1].name == "jstart" && checks[1].state == CheckState.ok);
}

