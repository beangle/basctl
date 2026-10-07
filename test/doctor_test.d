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
import std.socket : AddressFamily, InternetAddress, Socket, SocketOption, SocketOptionLevel,
  SocketType;
import std.string : replace, split;
import std.uuid : randomUUID;

/** PATH 上放一个假 jstart，测试里用不到真实命令。 */
private string fakeToolsDir() {
  auto dir = buildPath(tempDir, "basctl-doctor-" ~ randomUUID().toString());
  mkdirRecurse(dir);
  write(buildPath(dir, "jstart"), "#!/bin/sh\n");
  return dir;
}

/** 本机 setline 入口的写法，指向某个具体端口。 */
private string endpoint(int port) {
  return "127.0.0.1:" ~ port.to!string;
}

@("findOnPath finds a bare command on PATH and misses an unknown one") unittest {
  auto dir = fakeToolsDir();
  scope (exit) rmdirRecurse(dir);

  assert(findOnPath("jstart", dir) == buildPath(dir, "jstart"));
  assert(findOnPath("definitely-not-a-command", dir) == "");
}

@("doctor requires java and jstart, and setline only as a reachable entry") unittest {
  auto dir = fakeToolsDir();
  scope (exit) rmdirRecurse(dir);

  // 环境显式传入，不改进程环境：dub 的测试 runner 默认多线程并行（`-t 0`），
  // 进程级环境变量是共享状态，并行改会互相踩。
  auto env = ToolEnv("", dir, "");

  // 一份最小可解析的 server.xml：先不带 <setline>，再加一段。
  auto base = `<bas version="0.14.0">
  <engines><engine name="e" type="tomcat" version="11"/></engines>
  <farms><farm name="f" engine="e"><server name="s1" http="9980"/></farm></farms>
</bas>`;
  auto confFile = buildPath(dir, "server.xml");
  write(confFile, base);

  auto checks = checkTools(confFile, env);
  assert(checks.length == 3);
  assert(checks[0].name == "java" && checks[0].state == CheckState.missing);
  assert(checks[1].name == "jstart" && checks[1].state == CheckState.ok);
  assert(checks[2].name == "setline" && checks[2].state == CheckState.skipped);

  // 配了 <setline> 却没写入口地址是配置错误（解析不过），doctor 不把 setline 记为缺失
  write(confFile, base.replace("</bas>", `  <setline hostname="alice.localhost"/>
</bas>`));
  checks = checkTools(confFile, env);
  assert(checks[2].state == CheckState.skipped, checks[2].note);

  // 入口写在 <setline endpoint> 里：source 报 server.xml，端口没人听就是缺失。
  // 端口是共享资源：挑一个刚空出来的，被别的用例抢走就换一个重试。
  int freePort = 0;
  foreach (attempt; 0 .. 5) {
    auto probe = new Socket(AddressFamily.INET, SocketType.STREAM);
    probe.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
    probe.bind(new InternetAddress("127.0.0.1", 0));
    freePort = (cast(InternetAddress) probe.localAddress).port;
    probe.close();
    write(confFile, base.replace("</bas>", `  <setline hostname="alice.localhost" endpoint="`
        ~ endpoint(freePort) ~ `"/>
</bas>`));
    checks = checkTools(confFile, env);
    if (checks[2].state == CheckState.missing)
      break;
  }
  assert(checks[2].state == CheckState.missing, checks[2].note);
  assert(checks[2].note.canFind(endpoint(freePort)), checks[2].note);

  // 有人在听就算就绪：doctor 只认「入口可达」，不判断坐的是不是我们的 setline
  auto listener = new Socket(AddressFamily.INET, SocketType.STREAM);
  scope (exit) listener.close();
  listener.bind(new InternetAddress("127.0.0.1", 0));
  listener.listen(1);
  auto busyPort = (cast(InternetAddress) listener.localAddress).port;
  write(confFile, base.replace("</bas>", `  <setline hostname="alice.localhost" endpoint="`
      ~ endpoint(busyPort) ~ `"/>
</bas>`));
  checks = checkTools(confFile, env);
  assert(checks[2].state == CheckState.ok && checks[2].source == "server.xml");
  assert(checks[2].path == endpoint(busyPort));

}

@("doctor takes a command from its beangle_ env override when it is set") unittest {
  auto dir = fakeToolsDir();
  scope (exit) rmdirRecurse(dir);
  auto confFile = buildPath(dir, "server.xml");
  write(confFile, `<bas version="1">
  <engines><engine name="e" type="tomcat" version="11"/></engines>
  <farms><farm name="f" engine="e"><server name="s1" http="9980"/></farm></farms>
</bas>`);

  // 覆盖变量给的是路径：命中即用，source 报变量名（而不是 PATH）
  auto checks = checkTools(confFile, ToolEnv("", dir, buildPath(dir, "jstart")));
  assert(checks[1].state == CheckState.ok && checks[1].source == jstartEnvVar, checks[1].source);

  // 变量指向不存在的命令：报缺失，提示里带变量名
  checks = checkTools(confFile, ToolEnv("", dir, buildPath(dir, "nope")));
  assert(checks[1].state == CheckState.missing && checks[1].note.canFind(jstartEnvVar));
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
