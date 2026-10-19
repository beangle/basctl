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
 * Unit tests for bas.report：`report:os` / `report:bas` 两个 body 的形状。
 *
 * 本机事实取不到时**留空、不伪造**（Windows 开发机就是这种情况），所以这里只断言「字段该在的时候
 * 在、类型对」，不去断言具体的核数、内存量。
 */
module test.report_test;

import bas.config : parseServerXml;
import bas.report;
import bas.serverinfo : ServerInfo, WebappInfo, writeInstanceInfo;

import std.file : exists, mkdirRecurse, rmdirRecurse, write;
import std.json : JSONType, JSONValue;
import std.path : buildPath;
import std.uuid : randomUUID;

@("osReport reports capacity and water level, never fake values") unittest {
  auto body = osReport();

  assert(body.type == JSONType.object);
  assert(body["os"].type == JSONType.object);
  assert(body["cpu"].type == JSONType.object);
  assert(body["mem"].type == JSONType.object);
  assert(body["disk"].type == JSONType.array);

  version (linux) {
    assert(body["os"]["name"].str.length > 0);
    assert(body["os"]["kernel"].str.length > 0);
    assert(body["os"]["arch"].str.length > 0);
    assert(body["cpu"]["cores"].integer > 0);
    assert(body["cpu"]["load1"].type == JSONType.float_);
    assert(body["mem"]["total"].integer > 0);
    assert(body["mem"]["available"].integer > 0);
    // 根分区在真实挂载点里，至少有一条
    assert(body["disk"].array.length > 0);
    foreach (disk; body["disk"].array) {
      assert(disk["mount"].str.length > 0);
      assert(disk["total"].integer > 0);
      assert(disk["available"].integer >= 0);
      assert(disk["available"].integer <= disk["total"].integer);
    }
  }
}

@("basReport projects server.info, keeping its field names") unittest {
  auto home = buildPath("/tmp", "basctl-report-" ~ randomUUID().toString);
  auto instance = "platform.server1";
  scope (exit) {
    if (exists(home))
      rmdirRecurse(home);
  }

  auto info = ServerInfo("platform.server1", "tomcat-server-11.0.26", 20001,
      "2026-10-07T10:12:33+08:00", 0, [
        WebappInfo("portal", "gav://org.beangle.ems:beangle-ems-portal:4.20.13", "/",
            ["/", "/portal"]),
        WebappInfo("platform", "gav://org.beangle.ems:beangle-ems-ws:4.20.13", "/api/platform", [])
      ]);
  writeInstanceInfo(home, instance, info);

  // 没有 pid（实例没起来）就不在清单里——报的是"活着的实例"
  auto empty = basReport(home);
  assert(empty["instances"].array.length == 0);

  // 补一个"活着"的 pid：当前进程自己
  import core.sys.posix.unistd : getpid;
  auto alive = ServerInfo("platform.server1", "tomcat-server-11.0.26", 20001,
      "2026-10-07T10:12:33+08:00", cast(int) getpid(), [
        WebappInfo("portal", "gav://org.beangle.ems:beangle-ems-portal:4.20.13", "/",
            ["/", "/portal"]),
        WebappInfo("platform", "gav://org.beangle.ems:beangle-ems-ws:4.20.13", "/api/platform", [])
      ]);
  writeInstanceInfo(home, instance, alive);

  auto body = basReport(home);
  assert(body["instances"].array.length == 1);
  auto reported = body["instances"].array[0];
  assert(reported["id"].str == "platform.server1");
  assert(reported["engine"].str == "tomcat-server-11.0.26");
  assert(reported["httpPort"].integer == 20001);
  assert(reported["started"].str == "2026-10-07T10:12:33+08:00");
  assert(reported["pid"].integer > 0);
  assert(reported["webapps"].array.length == 2);
  assert(reported["webapps"].array[0]["context"].str == "/");
  assert(reported["webapps"].array[0]["urls"].array.length == 2);
  assert(reported["webapps"].array[1]["urls"].array.length == 0);
}

@("basReport declares local configured instances even when none are running") unittest {
  auto home = buildPath("/tmp", "basctl-report-declared-" ~ randomUUID().toString);
  scope (exit) {
    if (exists(home))
      rmdirRecurse(home);
  }

  auto container = parseServerXml(`<bas version="0.14.0">
    <engines><engine name="tomcat11" type="tomcat-server" version="11.0.24"/></engines>
    <farms><farm name="tools" engine="tomcat11"><server name="server1" http="20000"/></farm></farms>
    <webapps><webapp name="otk" uri="gav://org.beangle.otk:beangle-otk-ws:war:0.0.30"
      run-at="tools" path="/tools"/></webapps>
  </bas>`);

  auto body = basReport(home, container);
  assert(body["instances"].array.length == 0);
  assert(body["declared"].array.length == 1);
  auto declared = body["declared"].array[0];
  assert(declared["id"].str == "tools.server1");
  assert(declared["engine"].str == "tomcat-server-11.0.24");
  assert(declared["httpPort"].integer == 20000);
  assert(declared["webapps"].array.length == 1);
  assert(declared["webapps"].array[0]["context"].str == "/tools");
}
