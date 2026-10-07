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

/** Unit tests for bas.main status rendering (setline config helpers live in setlineproc_test). */
module test.main_test;

import bas.config : parseServerXml;
import bas.main : setlineStatusLine, staleStatusLine, statusLines;
import bas.setlineproc : setlineFileListen;
import bas.serverinfo : ServerInfo, WebappInfo;

import std.conv : to;
import std.file : mkdirRecurse, remove, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.process : thisProcessID;
import std.socket : AddressFamily, InternetAddress, Socket, SocketOption, SocketOptionLevel,
  SocketType;
import std.uuid : randomUUID;

@("setlineFileListen reads the listen field as written") unittest {
  // 用例并行跑，别用固定文件名去抢同一台机器上的同一个路径
  auto path = buildPath(tempDir, "basctl-setline-file-listen-" ~ randomUUID().toString() ~ ".json");
  scope (exit) remove(path);

  write(path, `{"listen":"127.0.0.1:8080","adminToken":"x"}`);
  assert(setlineFileListen(path) == "127.0.0.1:8080");

  write(path, `{"listen":8080}`);
  assert(setlineFileListen(path) == "8080");

  write(path, `{"routes":{}}`);
  assert(setlineFileListen(path) == "");

  write(path, "not json");
  assert(setlineFileListen(path) == "");
}

@("statusLines shows identity plus one line per webapp") unittest {
  ServerInfo info;
  info.id = "platform.server1";
  info.engine = "tomcat-server-11.0.26";
  info.httpPort = 20001;
  info.started = "2026-10-07T10:12:33+08:00";
  info.pid = 23145;
  info.webapps ~= WebappInfo("portal", "gav://org.beangle.ems:beangle-ems-portal:4.20.13",
      "/portal", []);
  info.webapps ~= WebappInfo("ROOT", "gav://org.beangle.otk:beangle-otk-ws:war:0.0.30", "/",
      ["/context1", "/context2"]);

  auto lines = statusLines(info);
  assert(lines.length == 3);
  assert(lines[0] == "platform.server1(pid=23145 port=20001 engine=tomcat-server-11.0.26"
      ~ " started=2026-10-07T10:12:33+08:00)");
  // 未声明 <url> 的 webapp 不写 urls（对外走 context），声明了的列出来
  assert(lines[1] == "  /portal  gav://org.beangle.ems:beangle-ems-portal:4.20.13");
  assert(lines[2] == "  /        gav://org.beangle.otk:beangle-otk-ws:war:0.0.30"
      ~ "  urls=/context1,/context2");
}

@("staleStatusLine marks run info left behind by a dead process") unittest {
  ServerInfo info;
  info.id = "platform.server2";
  info.httpPort = 20002;
  info.pid = 999;
  assert(staleStatusLine(info, "platform.server2") == "platform.server2(stale pid=999 port=20002)");

  info.id = "";
  info.pid = 0;
  assert(staleStatusLine(info, "platform.server2") == "platform.server2(stale port=20002)");
}

@("setlineStatusLine reports the entry address and whether it is up") unittest {
  auto home = buildPath(tempDir, "basctl-setline-status-" ~ randomUUID().toString());
  mkdirRecurse(home);
  scope (exit) rmdirRecurse(home);

  // 没记录 pid 且入口空闲：down。用例与别的用例并行跑，端口是共享资源——挑空闲端口时，
  // 刚释放的端口可能被别的用例抢走，所以换一个端口重试几次。
  string listen;
  bool down;
  foreach (attempt; 0 .. 5) {
    auto probe = new Socket(AddressFamily.INET, SocketType.STREAM);
    probe.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
    probe.bind(new InternetAddress("127.0.0.1", 0));
    listen = "127.0.0.1:" ~ (cast(InternetAddress) probe.localAddress).port.to!string;
    probe.close();
    if (setlineStatusLine(setlineContainer(listen), home) == "listen=" ~ listen ~ " (down)") {
      down = true;
      break;
    }
  }
  assert(down, "no probed port stayed free long enough to observe 'down'");

  auto cfg = setlineContainer(listen);

  // 记了自己拉起来的 pid（拿本进程凑数）并活着：报 pid
  mkdirRecurse(buildPath(home, "run"));
  write(buildPath(home, "run", "setline.pid"), thisProcessID.to!string ~ "\n");
  auto line = setlineStatusLine(cfg, home);
  assert(line == "listen=" ~ listen ~ " pid=" ~ thisProcessID.to!string, line);

  // 没配 <setline> 时整节省略
  assert(setlineStatusLine(parseServerXml(`<bas version="1"><engines/></bas>`), home) == "");

  // 地址写坏时报出来而不是崩
  assert(setlineStatusLine(parseServerXml(`<bas version="1"><setline listen="nope"/><engines/></bas>`),
      home) == "listen=nope (invalid address)");
}

/** 一份带 `<setline listen="...">` 的最小可解析配置。 */
private auto setlineContainer(string listen) {
  return parseServerXml(`<bas version="1">
    <setline listen="` ~ listen ~ `"/>
    <engines><engine name="t" type="tomcat" version="11"/></engines>
    <farms><farm name="f" engine="t"><server name="s1" http="0"/></farm></farms>
  </bas>`);
}
