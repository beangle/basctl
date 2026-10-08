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

/** Unit tests for bas.serverinfo. */
module test.serverinfo_test;

import bas.serverinfo;
import bas.serverstatus : processRunning;

import core.time : hours;
import std.algorithm : canFind;
import std.array : split;
import std.datetime : DateTime, SimpleTimeZone, SysTime, UTC;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.process : spawnProcess, thisProcessID, wait;
import std.string : startsWith, strip;
import std.uuid : randomUUID;

private string newHome(string tag) {
  auto root = buildPath(tempDir, "basctl-serverinfo-" ~ tag ~ "-" ~ randomUUID().toString());
  mkdirRecurse(root);
  return root;
}

/** 建出 `servers/<name>/`，模拟 basctl 已经为实例建过目录。 */
private string serverDir(string home, string name) {
  auto dir = buildPath(home, "servers", name);
  mkdirRecurse(dir);
  return dir;
}

private ServerInfo sample() {
  ServerInfo info;
  info.id = "platform.server1";
  info.engine = "tomcat-server-11.0.26";
  info.httpPort = 20001;
  info.started = "2026-10-07T10:12:33+08:00";
  info.pid = 23145;
  info.webapps ~= WebappInfo("portal", "gav://org.beangle.ems:beangle-ems-portal:4.20.13",
      "/portal", ["/portal"]);
  info.webapps ~= WebappInfo("ROOT", "gav://org.beangle.otk:beangle-otk-ws:war:0.0.30", "/",
      ["/context1", "/context2"]);
  return info;
}

@("renderServerInfo and parseServerInfo round trip") unittest {
  auto text = renderServerInfo(sample());
  auto info = parseServerInfo(text);

  assert(info.id == "platform.server1");
  assert(info.engine == "tomcat-server-11.0.26");
  assert(info.httpPort == 20001);
  assert(info.started == "2026-10-07T10:12:33+08:00");
  assert(info.pid == 23145);
  assert(info.webapps.length == 2);
  assert(info.webapps[0].id == "portal");
  assert(info.webapps[0].uri == "gav://org.beangle.ems:beangle-ems-portal:4.20.13");
  assert(info.webapps[0].context == "/portal");
  assert(info.webapps[0].urls == ["/portal"]);
  assert(info.webapps[1].id == "ROOT");
  assert(info.webapps[1].context == "/");
  assert(info.webapps[1].urls == ["/context1", "/context2"]);
}

@("renderServerInfo omits pid until the instance is confirmed") unittest {
  auto info = sample();
  info.pid = 0;
  auto text = renderServerInfo(info);
  assert(!text.split("\n").canFind("pid = 0"));
  assert(parseServerInfo(text).pid == 0);
}

@("parseServerInfo tolerates comments, unknown keys and bad values") unittest {
  auto info = parseServerInfo(`
; comment
# another comment

[server]
id = platform . server1
engine = jetty-12.1.14
http.port = not-a-number
started = 2026-10-07T10:12:33+08:00
pid = -3
future = whatever

[webapps]
uri = ignored

[webapp portal]
uri = gav://g:a:1
context = /portal
unknown = ignored
url = /a
url = /a
url = /b
`);
  assert(info.id == "platform . server1");
  assert(info.engine == "jetty-12.1.14");
  assert(info.httpPort == 0);
  assert(info.pid == 0);
  assert(info.webapps.length == 1);
  assert(info.webapps[0].urls == ["/a", "/b"]);
}

@("writeInstanceInfo replaces atomically") unittest {
  auto home = newHome("write");
  scope (exit) if (exists(home)) rmdirRecurse(home);

  serverDir(home, "f.s1");
  writeInstanceInfo(home, "f.s1", sample());

  auto path = serverInfoPath(home, "f.s1");
  assert(exists(path));
  assert(!exists(path ~ ".tmp"));

  auto info = readInstanceInfo(home, "f.s1");
  assert(!info.isNull && info.get.pid == 23145);

  // 补写 pid 是整文件重写，不是就地改
  auto updated = info.get;
  updated.pid = 999;
  writeInstanceInfo(home, "f.s1", updated);
  assert(readInstanceInfo(home, "f.s1").get.pid == 999);

  removeInstanceInfo(home, "f.s1");
  assert(!exists(path));
}

@("readInstanceInfo falls back to the directory name; instancePid reads server.info") unittest {
  auto home = newHome("pid");
  scope (exit) if (exists(home)) rmdirRecurse(home);

  serverDir(home, "f.s1");
  // 还没有运行信息时读不到 pid
  assert(instancePid(home, "f.s1").isNull);
  assert(readInstanceInfo(home, "f.s1").isNull);

  auto info = sample();
  info.id = "";
  writeInstanceInfo(home, "f.s1", info);
  assert(readInstanceInfo(home, "f.s1").get.id == "f.s1");
  assert(instancePid(home, "f.s1") == 23145);

  // 记录里还没有 pid 时也读不到
  info.pid = 0;
  writeInstanceInfo(home, "f.s1", info);
  assert(instancePid(home, "f.s1").isNull);
}

@("liveInstancePid requires a live process") unittest {
  auto home = newHome("live");
  scope (exit) if (exists(home)) rmdirRecurse(home);

  auto info = sample();
  info.pid = thisProcessID;
  writeInstanceInfo(home, "f.s1", info);
  assert(liveInstancePid(home, "f.s1") == thisProcessID);

  info.pid = 0;
  writeInstanceInfo(home, "f.s1", info);
  assert(liveInstancePid(home, "f.s1").isNull);
}

@("localIsoTimestamp keeps the local offset") unittest {
  auto local = SysTime(DateTime(2026, 10, 7, 10, 12, 33), new immutable SimpleTimeZone(hours(8)));
  assert(localIsoTimestamp(local) == "2026-10-07T10:12:33+08:00");
  assert(localIsoTimestamp(SysTime(DateTime(2026, 10, 7, 2, 12, 33), UTC()))
      == "2026-10-07T02:12:33+00:00");
}

@("oneLine keeps values on a single line") unittest {
  auto info = sample();
  info.id = "platform\n.server1";
  auto text = renderServerInfo(info);
  assert(readOneKey(text, "id") == "platform .server1");
}

/** 取 `[server]` 里某个键的原样值（测试用，避免自己再写一遍解析）。 */
private string readOneKey(string text, string key) {
  foreach (line; text.split("\n")) {
    auto trimmed = line.strip;
    if (trimmed.startsWith(key ~ " ="))
      return trimmed[key.length + 3 .. $].strip;
  }
  return "";
}

@("liveInstances keeps only instances whose pid is alive and whose port is known") unittest {
  auto home = newHome("live");
  scope (exit) rmdirRecurse(home);

  auto live = sample();
  live.id = "f.live";
  live.pid = thisProcessID;
  writeInstanceInfo(home, "f.live", live);

  auto stale = sample();
  stale.id = "f.stale";
  stale.pid = deadPid();
  writeInstanceInfo(home, "f.stale", stale);

  auto portless = sample();
  portless.id = "f.portless";
  portless.pid = thisProcessID;
  portless.httpPort = 0;
  writeInstanceInfo(home, "f.portless", portless);

  serverDir(home, "f.nodata"); // 目录存在但没有 server.info

  auto infos = liveInstances(home);
  assert(infos.length == 1 && infos[0].id == "f.live");
  assert(liveInstances(buildPath(home, "nowhere")).length == 0);
}

/** 一个确定已经死掉的 pid：起一个立刻退出的子进程，收尸之后这个号就空出来了。 */
private int deadPid() {
  auto child = spawnProcess(["/bin/sh", "-c", "exit 0"]);
  auto pid = child.processID;
  wait(child);
  assert(!processRunning(pid));
  return pid;
}
