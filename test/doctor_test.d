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

import std.algorithm : canFind;
import std.array : join;
import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.process : environment;
import std.uuid : randomUUID;
import std.string : replace, split;

/** PATH 上放一个假 jstart（不含 setline），测试里用不到真实命令。 */
private string fakeToolsDir() {
  auto dir = buildPath(tempDir, "basctl-doctor-" ~ randomUUID().toString());
  mkdirRecurse(dir);
  write(buildPath(dir, "jstart"), "#!/bin/sh\n");
  return dir;
}

/** 把环境变量改成给定值，返回恢复用的旧值。 */
private string setEnv(string name, string value) {
  auto had = name in environment;
  auto previous = had ? environment.get(name) : "";
  environment[name] = value;
  return had ? "1" ~ previous : "";
}

/** 恢复 {@link setEnv} 改过的环境变量。 */
private void restoreEnv(string name, string saved) {
  if (saved.length && saved[0] == '1')
    environment[name] = saved[1 .. $];
  else
    environment.remove(name);
}

@("findOnPath finds a bare command on PATH and misses an unknown one") unittest {
  auto dir = fakeToolsDir();
  scope (exit) rmdirRecurse(dir);
  auto savedPath = setEnv("PATH", dir);
  scope (exit) restoreEnv("PATH", savedPath);

  assert(findOnPath("jstart") == buildPath(dir, "jstart"));
  assert(findOnPath("definitely-not-a-command") == "");
}

@("doctor requires java and jstart, and setline only when <setline> is configured") unittest {
  auto dir = fakeToolsDir();
  scope (exit) rmdirRecurse(dir);
  auto savedPath = setEnv("PATH", dir);
  scope (exit) restoreEnv("PATH", savedPath);
  auto savedJavaHome = setEnv("JAVA_HOME", "");
  scope (exit) restoreEnv("JAVA_HOME", savedJavaHome);
  auto savedJstart = setEnv("bas_jstart", "");
  scope (exit) restoreEnv("bas_jstart", savedJstart);
  auto savedSetline = setEnv("bas_setline", "");
  scope (exit) restoreEnv("bas_setline", savedSetline);

  // 一份最小可解析的 server.xml：先不带 <setline>，再加一段。
  auto base = `<bas version="0.14.0">
  <engines><engine name="e" type="tomcat" version="11"/></engines>
  <farms><farm name="f" engine="e"><server name="s1" http="9980"/></farm></farms>
</bas>`;
  auto confFile = buildPath(dir, "server.xml");
  write(confFile, base);

  auto checks = checkTools(confFile);
  assert(checks.length == 3);
  assert(checks[0].name == "java" && checks[0].state == CheckState.missing);
  assert(checks[1].name == "jstart" && checks[1].state == CheckState.ok);
  assert(checks[2].name == "setline" && checks[2].state == CheckState.skipped);

  write(confFile, base.replace("</bas>", `  <setline listen="127.0.0.1:18080"/>
</bas>`));
  checks = checkTools(confFile);
  assert(checks[2].state == CheckState.missing, "setline becomes required once <setline> is declared");
  assert(checks[2].note.canFind("127.0.0.1:18080"));

  // setline 装到 PATH 上后就绪。
  write(buildPath(dir, "setline"), "#!/bin/sh\n");
  checks = checkTools(confFile);
  assert(checks[2].state == CheckState.ok && checks[2].source == "PATH");
}

@("renderChecks prints one line per command plus a verdict") unittest {
  ToolCheck[] checks = [
    ToolCheck("java", CheckState.ok, "/opt/jdk/bin/java", "JAVA_HOME", ""),
    ToolCheck("jstart", CheckState.missing, "", "", "install jstart"),
    ToolCheck("setline", CheckState.skipped, "", "", "not required: no <setline>"),
  ];
  auto text = renderChecks("/tmp/missing-server.xml", checks);
  auto lines = text.split("\n");
  assert(lines.length == 5, text);
  assert(lines[0].canFind("config") && lines[0].canFind("not found"));
  assert(lines[1].canFind("java") && lines[1].canFind("ok") && lines[1].canFind("JAVA_HOME"));
  assert(lines[2].canFind("jstart") && lines[2].canFind("MISSING"));
  assert(lines[3].canFind("setline") && lines[3].canFind("skip"));
  assert(lines[4] == "doctor: 1 required command(s) missing.");
}
