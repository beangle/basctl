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

/** Unit tests for bas.main status rendering and setline config helpers. */
module test.main_test;

import bas.main : setlineFileListen, staleStatusLine, statusLines;
import bas.serverinfo : ServerInfo, WebappInfo;

import std.file : remove, write;

@("setlineFileListen reads the listen field as written") unittest {
  auto path = "/tmp/basctl-setline-file-listen.json";
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
