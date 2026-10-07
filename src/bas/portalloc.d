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
 * 动态端口：`<server http="0">`（或缺省）时由 basctl 在端口区间内挑一个空闲端口，用
 * `--port=<n>` 传给应用（与静态端口同一条参数，引擎不需要区分），并写进 `server.info`。
 *
 * 应用不自己选端口，`status` 与 setline 的对账因此都不必反查（`ss` / `netstat`），Windows
 * 开发机上同样可用。
 *
 * 算法（探测与落盘都在 `servers/.ports.lock` 的 `flock` 内完成）：
 *
 *  1. 本实例上次记录的端口仍在区间内且空闲时**优先复用**——重启后端口稳定，书签与 setline
 *     路由都不用重新记；
 *  2. 否则在区间内**顺序找第一个空闲端口**（可预测，便于人工排查）；
 *  3. 「空闲」= 没有别的实例记着它（`server.info`），且能独占 `bind` 一次。
 *
 * 锁只覆盖「探测 + 写第一段」，不覆盖 JVM 启动过程，所以并发 `start` 既不重号、也不会长时间
 * 占着锁。`bind` 探测与真正的监听之间仍有理论上的竞争窗口，属于可接受（单机 / 开发场景），
 * 真撞上了会在启动日志里直接体现。
 */
module bas.portalloc;

import bas.net : canBindPort;
import bas.serverinfo : readInstanceInfo;
import bas.serverstatus : processRunning;

import std.algorithm : canFind;
import std.conv : to;
import std.file : SpanMode, dirEntries, exists, isDir, mkdirRecurse;
import std.format : format;
import std.path : baseName, buildPath, dirName;
import std.string : indexOf, strip, toStringz;
import std.typecons : Nullable, nullable;

/** 端口区间（含两端）。 */
struct PortRange {
  ushort from;
  ushort to;

  /** 展示用写法：`20000-29999`。 */
  string toString() const {
    return format!"%s-%s"(from, to);
  }
}

/**
 * 缺省区间 `20000-29999`，理由：
 *
 *  - 高于特权端口（1024 以上），不需要 root；
 *  - 低于 Linux 缺省的临时端口范围 `32768-60999`（`net.ipv4.ip_local_port_range`）：否则本机
 *    出站连接可能先把我们想用的端口借走；
 *  - 避开 k8s NodePort（30000-32767），容器里跑也不冲突；
 *  - 避开常见开发端口（8000 / 8080 / 9000 等）。
 *
 * 区间属于**机器相关的环境**而不是拓扑，所以用 `--port-range=<from>-<to>` 给出，不写进
 * `server.xml`，也不设环境变量——一个旋钮就够。
 */
enum defaultPortRange = PortRange(20000, 29999);

/** 缺省区间的文字形式（命令行提示用）。 */
enum defaultPortRangeText = "20000-29999";

/**
 * 解析 `--port-range` 取值：`<from>-<to>`；也接受单值 `8080`（等价 `8080-8080`）。
 * 非法写法抛异常，由调用方打印成命令行错误。
 */
PortRange parsePortRange(string text) {
  auto value = strip(text);
  auto dash = value.indexOf('-');
  auto fromText = dash < 0 ? value : strip(value[0 .. dash]);
  auto toText = dash < 0 ? value : strip(value[dash + 1 .. $]);
  auto from = portOf(fromText, text);
  auto to = portOf(toText, text);
  if (from > to)
    throw new Exception("Invalid port range " ~ text ~ ": from is greater than to");
  return PortRange(from, to);
}

/**
 * 在区间内挑一个可用端口：优先复用 `previous`（本实例上次的端口），否则按顺序取第一个空闲的。
 *
 * `isFree` 由调用方给出「这个端口能不能用」（别人记着的、已经有人监听的都算不能用），
 * 因此本函数是纯计算，可以直接测。区间里一个可用的都没有时返回空。
 */
Nullable!ushort pickPort(PortRange range, int previous, scope bool delegate(ushort) isFree) {
  if (previous > 0 && previous >= range.from && previous <= range.to
      && isFree(cast(ushort) previous))
    return nullable(cast(ushort) previous);
  for (int port = range.from; port <= range.to; port++) {
    if (isFree(cast(ushort) port))
      return nullable(cast(ushort) port);
  }
  return Nullable!ushort.init;
}

/**
 * 别的实例记着的端口（`servers/<name>/server.info`）。
 *
 * 进程活着、或者文件里还没有 pid（一次正在进行中的启动预留）都算占用；pid 已死的陈旧信息不算
 * ——它的端口可以回收。`selfId` 是自己，跳过：自己上次的端口正是复用的候选。
 */
int[] heldPorts(string basHome, string selfId) {
  int[] ports;
  auto serversDir = buildPath(basHome, "servers");
  if (!exists(serversDir) || !isDir(serversDir))
    return ports;
  foreach (entry; dirEntries(serversDir, SpanMode.shallow)) {
    if (!entry.isDir)
      continue;
    auto name = baseName(entry.name);
    if (name == selfId)
      continue;
    auto info = readInstanceInfo(basHome, name);
    if (info.isNull || info.get.httpPort <= 0)
      continue;
    if (info.get.pid > 0 && !processRunning(info.get.pid))
      continue;
    ports ~= info.get.httpPort;
  }
  return ports;
}

/** 端口分配结果：`port` 为空表示失败，`reason` 给调用方打印原因。 */
struct PortReservation {
  Nullable!ushort port;
  string reason;
}

/**
 * 在锁内挑端口并落盘：挑中后回调 `persist`，由调用方把端口写进自己的运行信息（第一段，兼作
 * 预留）。并发 `basctl start` 因此不会撞到同一个端口，也不会长时间互相等待——锁只覆盖
 * 「探测 + 落盘」，不覆盖 JVM 启动。
 */
PortReservation reservePort(string basHome, string selfId, PortRange range, int previous,
    scope void delegate(ushort) persist) {
  Nullable!ushort chosen;
  string reason;
  auto locked = withPortLock(basHome, {
    auto held = heldPorts(basHome, selfId);
    auto port = pickPort(range, previous,
        (candidate) => !held.canFind(candidate) && canBindPort("", candidate));
    if (port.isNull) {
      reason = "no free port in " ~ range.toString();
      return;
    }
    persist(port.get);
    chosen = port;
  });
  if (!locked)
    return PortReservation(Nullable!ushort.init, "cannot lock " ~ portsLockPath(basHome));
  return PortReservation(chosen, reason);
}

/** 端口分配用的锁文件：`servers/.ports.lock`（机器级，不是每个实例一个）。 */
string portsLockPath(string basHome) {
  return buildPath(basHome, "servers", ".ports.lock");
}

/**
 * 在 `servers/.ports.lock` 上互斥执行 `body`，拿到锁返回 true。
 *
 * 用 `flock` 而不是自己维护锁文件：进程崩了内核自动释放，不会留下需要人工清理的死锁。
 * 没有 flock 绑定的平台（Windows 开发机）退化为不加锁——同一台机器上并发 `basctl start`
 * 不是要防的场景，端口探测本身仍然是保守的。
 */
private bool withPortLock(string basHome, scope void delegate() body) {
  version (linux) {
    import core.sys.posix.fcntl : O_CREAT, O_RDWR, open;
    import core.sys.linux.sys.file : LOCK_EX, LOCK_UN, flock;
    import core.sys.posix.unistd : close;

    auto path = portsLockPath(basHome);
    mkdirRecurse(dirName(path));
    auto fd = open(path.toStringz, O_CREAT | O_RDWR, 0b110_100_100); // 0644
    if (fd < 0)
      return false;
    scope (exit) close(fd);
    if (flock(fd, LOCK_EX) != 0)
      return false;
    scope (exit) flock(fd, LOCK_UN);
    body();
    return true;
  } else {
    body();
    return true;
  }
}

/** 解析单个端口号，越界或非数字即抛异常（带上原始写法便于定位）。 */
private ushort portOf(string text, string whole) {
  int port;
  try
    port = strip(text).to!int;
  catch (Exception)
    throw new Exception("Invalid port range " ~ whole);
  if (port <= 0 || port > 65535)
    throw new Exception("Invalid port range " ~ whole);
  return cast(ushort) port;
}
