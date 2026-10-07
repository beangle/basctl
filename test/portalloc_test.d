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

/** Unit tests for bas.portalloc. */
module test.portalloc_test;

import bas.portalloc;
import bas.serverinfo : ServerInfo, WebappInfo, writeInstanceInfo;
import bas.serverstatus : processRunning;

import std.algorithm : canFind;
import std.exception : assertThrown;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
import std.path : buildPath;
import std.process : spawnProcess, thisProcessID, wait;
import std.uuid : randomUUID;

private string newHome(string tag) {
  auto root = buildPath(tempDir, "basctl-ports-" ~ tag ~ "-" ~ randomUUID().toString());
  mkdirRecurse(root);
  return root;
}

private ServerInfo infoOf(string id, int port, int pid) {
  ServerInfo info;
  info.id = id;
  info.engine = "tomcat-server-11.0.26";
  info.httpPort = cast(ushort) port;
  info.started = "2026-10-07T10:12:33+08:00";
  info.pid = pid;
  return info;
}

/** 一个确定已经死掉的 pid：起一个立刻退出的子进程，收尸之后这个号就空出来了。 */
private int deadPid() {
  auto child = spawnProcess(["/bin/sh", "-c", "exit 0"]);
  auto pid = child.processID;
  wait(child);
  assert(!processRunning(pid));
  return pid;
}

@("parsePortRange accepts ranges and single ports") unittest {
  auto range = parsePortRange("20000-29999");
  assert(range.from == 20000 && range.to == 29999);
  assert(range.toString() == "20000-29999");

  auto single = parsePortRange(" 8080 ");
  assert(single.from == 8080 && single.to == 8080);

  assert(defaultPortRange.toString() == defaultPortRangeText);
}

@("parsePortRange rejects invalid values") unittest {
  assertThrown(parsePortRange(""));
  assertThrown(parsePortRange("abc"));
  assertThrown(parsePortRange("0-10"));
  assertThrown(parsePortRange("10-0"));
  assertThrown(parsePortRange("100-99"));
  assertThrown(parsePortRange("0-70000"));
}

@("pickPort reuses the previous port when it is free") unittest {
  auto range = PortRange(20000, 20010);
  bool delegate(ushort) free = (port) => true;
  // 上次的端口还在区间内且空闲：优先复用它，而不是区间里的第一个
  assert(pickPort(range, 20005, free) == 20005);
  // 上次的端口已经不在区间内（比如换了 --port-range）：退回顺序查找
  assert(pickPort(range, 25000, free) == 20000);
}

@("pickPort skips ports that are taken and searches in order") unittest {
  int[] taken = [20000, 20002, 20003];
  bool delegate(ushort) free = (port) => !taken.canFind(cast(int) port);
  assert(pickPort(PortRange(20000, 20010), 0, free) == 20001);
  assert(pickPort(PortRange(20000, 20010), 20000, free) == 20001);
}

@("pickPort returns nothing when the range is exhausted") unittest {
  assert(pickPort(PortRange(20000, 20002), 0, (port) => false).isNull);
  assert(pickPort(PortRange(20000, 20002), 30000, (port) => false).isNull);
}

@("heldPorts counts reservations and live instances, skipping self and stale") unittest {
  auto home = newHome("held");
  scope (exit) if (exists(home)) rmdirRecurse(home);

  // 别的实例、进程活着
  writeInstanceInfo(home, "f.alive", infoOf("f.alive", 20001, thisProcessID));
  // 别的实例、还没启动完（没有 pid）：一次正在进行的启动预留
  writeInstanceInfo(home, "f.reserved", infoOf("f.reserved", 20002, 0));
  // 别的实例、pid 已死：端口可以回收
  writeInstanceInfo(home, "f.stale", infoOf("f.stale", 20003, deadPid()));
  // 自己：不参与判断（自己上次的端口正是复用的候选）
  writeInstanceInfo(home, "f.self", infoOf("f.self", 20004, 0));

  auto held = heldPorts(home, "f.self");
  assert(held.canFind(20001));
  assert(held.canFind(20002));
  assert(!held.canFind(20003));
  assert(!held.canFind(20004));
}

@("reservePort persists the choice and prefers it next time") unittest {
  auto home = newHome("reserve");
  scope (exit) if (exists(home)) rmdirRecurse(home);

  auto range = PortRange(20000, 20050);
  ushort persisted;
  auto first = reservePort(home, "f.s1", range, 0, (ushort port) { persisted = port; });
  assert(!first.port.isNull && first.reason == "");
  assert(persisted == first.port.get);

  // 同一个实例再次分配：复用上次那个端口，不必重新找
  ushort again;
  auto second = reservePort(home, "f.s1", range, first.port.get, (ushort port) { again = port; });
  assert(!second.port.isNull);
  assert(second.port.get == first.port.get);
  assert(again == first.port.get);
}

@("reservePort reports an exhausted range") unittest {
  auto home = newHome("exhausted");
  scope (exit) if (exists(home)) rmdirRecurse(home);

  // 单值区间：要么拿到这一个端口并落盘，要么明确说「区间没有空闲端口」（本机 20000 已被占用时）
  int persisted;
  auto result = reservePort(home, "f.s1", PortRange(20000, 20000), 0, (ushort port) { persisted++; });
  if (result.port.isNull) {
    assert(persisted == 0);
    assert(result.reason.canFind("no free port in 20000-20000"));
  } else {
    assert(result.port.get == 20000);
    assert(persisted == 1);
  }
}

@("portsLockPath keeps machine level state out of instance dirs") unittest {
  assert(portsLockPath("/opt/bas") == buildPath("/opt/bas", "servers", ".ports.lock"));
}
