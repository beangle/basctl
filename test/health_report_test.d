/* Copyright (C) 2026 Beangle
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

/** Unit tests for the lightweight `report:health` body. */
module test.health_report_test;

import bas.config : parseServerXml;
import bas.report : healthReport;
import bas.serverinfo : ServerInfo, writeInstanceInfo;

import core.sys.posix.unistd : getpid;
import std.file : exists, rmdirRecurse;
import std.path : buildPath;
import std.uuid : randomUUID;

@("healthReport keeps local declared instances and reports running or stopped") unittest {
  auto home = buildPath("/tmp", "basctl-health-" ~ randomUUID().toString);
  scope (exit) {
    if (exists(home))
      rmdirRecurse(home);
  }

  writeInstanceInfo(home, "platform.server1",
      ServerInfo("platform.server1", "tomcat-server-11.0.24", 20001,
          "2026-10-07T10:12:33+08:00", cast(int) getpid(), []));

  auto runningOnly = healthReport(home);
  assert(runningOnly["servers"].array.length == 1);
  assert(runningOnly["servers"][0]["id"].str == "platform.server1");
  assert(runningOnly["servers"][0]["state"].str == "running");

  auto container = parseServerXml(`<bas version="0.14.0">
    <hosts>
      <host name="local" ip="127.0.0.1"/>
      <host name="remote" ip="192.0.2.10"/>
    </hosts>
    <engines><engine name="tomcat11" type="tomcat-server" version="11.0.24"/></engines>
    <farms>
      <farm name="platform" engine="tomcat11">
        <server name="server1" http="20001" host="local"/>
      </farm>
      <farm name="portal" engine="tomcat11">
        <server name="server1" http="20002" host="local"/>
      </farm>
      <farm name="remote" engine="tomcat11">
        <server name="server1" http="20003" host="remote"/>
      </farm>
    </farms>
  </bas>`);

  auto body = healthReport(home, container);
  auto servers = body["servers"].array;
  assert(servers.length == 2, body.toString);
  assert(servers[0]["id"].str == "platform.server1");
  assert(servers[0]["state"].str == "running");
  assert(servers[1]["id"].str == "portal.server1");
  assert(servers[1]["state"].str == "stopped");
  assert(("declared" in body.object) is null);
}
