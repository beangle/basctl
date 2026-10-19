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
 * 本机事实 → 通道原语的 body（`report:os` / `report:bas`）。
 *
 * 两条规矩：
 *
 * - **运行状态只报事实**：`instances` 直接取自 `servers/<实例>/server.info`
 *   （{@link bas.serverinfo.liveInstances}），不从配置推断谁在运行。
 * - **另报可操作清单**：`declared` 是本机 `server.xml` 声明的实例，供控制台在实例停止后仍能
 *   发起 `service:start`；它与 `instances` 分开，不把配置意图混进运行事实。
 * - **取不到就留空，不伪造**：Windows 开发机上没有 `/proc`，那些字段就缺着，控制台按「不可用」
 *   渲染（与 `status` 不依赖 `ss` / `netstat` 是同一条路线）。
 *
 * 字段名与 `docs/channel-protocol.md` 一一对应；`report:os` 与 `report:bas` 都是**整份替换**语义，
 * 所以两边各自采集、各自上报，互不牵连（节拍不同，见文档）。
 */
module bas.report;

import bas.config : Container, engineRefText;
import bas.net : localAddresses;
import bas.serverinfo : liveInstances;

import std.algorithm : canFind;
import std.json : JSONValue;

/** `report:os` 的 body：OS / CPU / 内存 / 磁盘的「家底 + 水位」。 */
JSONValue osReport() {
  JSONValue body = [
    "os": osFields(),
    "cpu": cpuFields(),
    "mem": memFields(),
    "disk": JSONValue(diskFields())
  ];
  return body;
}

/**
 * `report:bas` 的 body：`instances` 是本机活着的实例，`declared` 是本机配置声明的实例。
 *
 * 前者每项与 `server.info` 的 `[server]` 同构（字段名照搬，控制台不必再翻译一层）；后者只含
 * 启动控制需要的静态字段，让控制台在实例停止后仍有「启动」入口。两者按 `id` 合并。
 */
JSONValue basReport(string basHome, Container container = null) {
  JSONValue[] instances;
  foreach (info; liveInstances(basHome)) {
    JSONValue[] webapps;
    foreach (app; info.webapps) {
      JSONValue[] urls;
      foreach (url; app.urls)
        urls ~= JSONValue(url);
      webapps ~= JSONValue([
        "id": JSONValue(app.id),
        "uri": JSONValue(app.uri),
        "context": JSONValue(app.context),
        "urls": JSONValue(urls)
      ]);
    }
    instances ~= JSONValue([
      "id": JSONValue(info.id),
      "pid": JSONValue(cast(long) info.pid),
      "engine": JSONValue(info.engine),
      "httpPort": JSONValue(cast(long) info.httpPort),
      "started": JSONValue(info.started),
      "webapps": JSONValue(webapps)
    ]);
  }
  JSONValue[] declared;
  if (container !is null) {
    auto ips = localAddresses();
    foreach (farm; container.farms) {
      foreach (server; farm.servers) {
        if (!ips.canFind(server.host.ip))
          continue;
        JSONValue[] webapps;
        foreach (app; container.getWebapps(server)) {
          JSONValue[] urls;
          foreach (url; app.urls)
            urls ~= JSONValue(url);
          webapps ~= JSONValue([
            "uri": JSONValue(app.uri),
            "context": JSONValue(app.contextPath.length ? app.contextPath : "/"),
            "urls": JSONValue(urls)
          ]);
        }
        JSONValue item = [
          "id": JSONValue(server.qualifiedName),
          "engine": JSONValue(engineRefText(server.farm.engine)),
          "webapps": JSONValue(webapps)
        ];
        if (server.http > 0)
          item["httpPort"] = JSONValue(cast(long) server.http);
        declared ~= item;
      }
    }
  }

  JSONValue body = ["instances": JSONValue(instances)];
  if (container !is null)
    body["declared"] = JSONValue(declared);
  return body;
}

private:

/** `os`：发行版 / 内核 / 架构。取不到（如 Windows）就留空。 */
private JSONValue osFields() {
  string name;
  string kernel;
  string arch;

  version (linux) {
    import core.sys.posix.sys.utsname : uname, utsname;
    import std.string : fromStringz;

    utsname u;
    if (uname(&u) == 0) {
      kernel = fromStringz(u.release).idup;
      arch = fromStringz(u.machine).idup;
      name = fromStringz(u.sysname).idup;
    }
    auto pretty = osPrettyName();
    if (pretty.length)
      name = pretty;
  }

  return JSONValue([
    "name": JSONValue(name),
    "kernel": JSONValue(kernel),
    "arch": JSONValue(arch)
  ]);
}

/** `/etc/os-release` 的 `PRETTY_NAME`：`name` 报发行版比报内核名有用。读不到就返回空串。 */
private string osPrettyName() {
  import std.algorithm : startsWith;
  import std.file : exists, readText;
  import std.string : splitLines;

  if (!exists("/etc/os-release"))
    return "";
  foreach (line; readText("/etc/os-release").splitLines()) {
    if (!line.startsWith("PRETTY_NAME="))
      continue;
    auto value = line["PRETTY_NAME=".length .. $];
    if (value.length >= 2 && value[0] == '"' && value[$ - 1] == '"')
      value = value[1 .. $ - 1];
    return value;
  }
  return "";
}

/** `cpu`：核数（配置）+ 1/5/15 分钟负载（水位，取不到就没有）。 */
private JSONValue cpuFields() {
  import std.parallelism : totalCPUs;

  JSONValue fields = ["cores": JSONValue(cast(long) totalCPUs)];
  version (linux) {
    auto loads = loadAverage();
    if (loads.length == 3) {
      fields["load1"] = JSONValue(loads[0]);
      fields["load5"] = JSONValue(loads[1]);
      fields["load15"] = JSONValue(loads[2]);
    }
  }
  return fields;
}

/** `/proc/loadavg` 的前三个数（1/5/15 分钟平均负载）；读不到返回空数组。 */
private double[] loadAverage() {
  import std.conv : to;
  import std.file : exists, readText;
  import std.range : take;
  import std.string : split;
  import std.string : strip;

  if (!exists("/proc/loadavg"))
    return [];
  double[] loads;
  try {
    foreach (field; readText("/proc/loadavg").strip.split(' ').take(3))
      loads ~= field.to!double;
  } catch (Exception)
    return [];
  return loads;
}

/** `mem`：总量（配置）与可用量（水位），单位字节；取不到就留空。 */
private JSONValue memFields() {
  JSONValue fields;
  version (linux) {
    auto mem = memInfo();
    if (auto total = "MemTotal" in mem)
      fields["total"] = JSONValue(*total);
    if (auto available = "MemAvailable" in mem)
      fields["available"] = JSONValue(*available);
  }
  return fields;
}

/** `/proc/meminfo` 里关心的两项，单位字节（文件里是 kB）。 */
private long[string] memInfo() {
  import std.algorithm : startsWith;
  import std.conv : to;
  import std.file : exists, readText;
  import std.string : indexOf, splitLines, strip;

  long[string] mem;
  if (!exists("/proc/meminfo"))
    return mem;
  foreach (line; readText("/proc/meminfo").splitLines()) {
    auto colon = line.indexOf(':');
    if (colon < 0)
      continue;
    auto key = line[0 .. colon].strip;
    if (key != "MemTotal" && key != "MemAvailable")
      continue;
    auto rest = line[colon + 1 .. $].strip;
    auto space = rest.indexOf(' ');
    if (space > 0)
      rest = rest[0 .. space];
    try
      mem[key] = rest.to!long * 1024;
    catch (Exception)
      continue;
  }
  return mem;
}

/** `disk`：每个真实挂载点的总量与可用量，单位字节；取不到就是空数组。 */
private JSONValue[] diskFields() {
  JSONValue[] disks;
  version (linux) {
    foreach (mount; mounts()) {
      auto space = diskSpace(mount.point);
      // 容量报 0 的挂载点（fuse 的门户目录之类）没有「容量」可言，与伪文件系统同理跳过
      if (space is null || space.total <= 0)
        continue;
      disks ~= JSONValue([
        "mount": JSONValue(mount.point),
        "total": JSONValue(space.total),
        "available": JSONValue(space.available)
      ]);
    }
  }
  return disks;
}

/** 一个挂载点：设备与挂载路径。 */
private struct Mount {
  string device;
  string point;
}

/** 一个挂载点的容量。 */
private struct DiskSpace {
  long total;
  long available;
}

/**
 * `/proc/mounts` 里的真实文件系统。伪文件系统（proc / sysfs / tmpfs / cgroup...）不算——它们没有
 * 「容量」可言，报上去只会让控制台显示一堆 0 和满盘。
 */
private Mount[] mounts() {
  import std.algorithm : canFind, splitter;
  import std.file : exists, readText;
  import std.string : splitLines;

  enum ignored = [
    "proc", "sysfs", "tmpfs", "devtmpfs", "devpts", "cgroup", "cgroup2", "securityfs",
    "pstore", "bpf", "autofs", "mqueue", "hugetlbfs", "debugfs", "tracefs", "configfs",
    "fusectl", "nsfs", "ramfs", "efivarfs", "binfmt_misc", "rpc_pipefs"
  ];

  Mount[] result;
  if (!exists("/proc/mounts"))
    return result;
  foreach (line; readText("/proc/mounts").splitLines()) {
    auto fields = line.splitter(' ');
    if (fields.empty)
      continue;
    auto device = fields.front;
    fields.popFront();
    if (fields.empty)
      continue;
    auto point = fields.front;
    fields.popFront();
    if (fields.empty)
      continue;
    auto fsType = fields.front;
    if (ignored.canFind(fsType))
      continue;
    result ~= Mount(device, point);
  }
  return result;
}

/** 挂载点的容量；`statvfs` 失败（权限、已卸载）返回 null，跳过不报。 */
private DiskSpace* diskSpace(string point) {
  version (linux) {
    import core.sys.posix.sys.statvfs : statvfs, statvfs_t;
    import std.string : toStringz;

    statvfs_t fs;
    if (statvfs(point.toStringz, &fs) != 0)
      return null;
    auto blockSize = fs.f_frsize ? fs.f_frsize : fs.f_bsize;
    auto space = new DiskSpace(cast(long) (blockSize * fs.f_blocks),
        cast(long) (blockSize * fs.f_bavail));
    return space;
  } else
    return null;
}
