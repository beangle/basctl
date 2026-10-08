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
 * 实例运行信息 `servers/<name>/server.info`：谁在跑、进程号多少、实际监听哪个端口、跑了哪些
 * webapp、对外暴露哪些 url。
 *
 * 它是 `basctl start` 写、`basctl status` / `basctl stop` 与 setline 路由对账共用的「现状」
 * 视图。对账要的正是「此刻谁活着、在哪个端口、占哪些 url」——重新解析 `server.xml` 会引入
 * 歧义：配置可能已经被改了，而跑着的实例还是启动时那一份。
 *
 * 生命周期见 docs/server-info.md：`start` 分配好端口先写第一段（无 `pid`，同时兼作端口预留），
 * 确认存活后补 `pid`，启动失败或 `stop` 之后删除。文件里**不记状态**：running / stale 一律由
 * pid 是否存活推导，少一个需要同步的字段。
 *
 * 只有 basctl 写这个文件（原子替换），其余进程只读。
 */
module bas.serverinfo;

import bas.fsutil : mkdirPrivate;
import bas.serverstatus : processRunning;

import std.algorithm : canFind, sort;
import std.array : appender;
import std.conv : to;
import std.datetime : SysTime;
import std.file : SpanMode, dirEntries, exists, isDir, readText, remove, rename, write;
import std.format : format;
import std.path : baseName, buildPath, dirName;
import std.string : indexOf, replace, split, startsWith, strip, toLower;
import std.typecons : Nullable, nullable;

/** 一个 webapp 的运行信息（`[webapp <id>]` 分节）。 */
struct WebappInfo {
  /** 分节 id，与 launch spec 的 `[subapp <id>]` 同源（都由 context path 推导）。 */
  string id;
  /** 应用坐标，与 `<webapp uri>` 一致（`gav://` / `http(s)://` / 本地路径）。 */
  string uri;
  /** 容器内的上下文路径；ROOT 记作 `/`。 */
  string context;
  /** 对外暴露的 URL 前缀（对应 `<webapp><url path>`）；空表示回退 `context`。 */
  string[] urls;
}

/** 一个实例的运行信息（`server.info`）。 */
struct ServerInfo {
  string id;
  /** 容器形态与版本：`<type>-<version>`（见 `bas.config.engineRefText`）。 */
  string engine;
  /** 实际监听端口：静态端口取自 `<server http>`，动态端口由 basctl 分配。 */
  ushort httpPort;
  /** 启动时间，本机时区的 ISO-8601（`2026-10-07T10:12:33+08:00`）。 */
  string started;
  /** 实例进程 pid；启动完成前（进程还没起来）为 0。 */
  int pid;
  WebappInfo[] webapps;
}

/**
 * 渲染为 INI 文本：`[section]` + `key = value`，同一分节内同名键重复即列表（目前只有 `url`）。
 *
 * 值不做转义，所以先折掉其中的换行——运行信息是一行一个键，读者按行切。
 */
string renderServerInfo(const ServerInfo info) {
  auto sb = appender!string;
  sb.put("; server.info - 实例运行信息，由 basctl 写入，请勿手工修改。\n");
  sb.put("; 字段语义见 basctl 的 docs/server-info.md。\n\n");
  sb.put("[server]\n");
  sb.put("id = " ~ oneLine(info.id) ~ "\n");
  if (info.engine.length)
    sb.put("engine = " ~ oneLine(info.engine) ~ "\n");
  sb.put("http.port = " ~ info.httpPort.to!string ~ "\n");
  if (info.started.length)
    sb.put("started = " ~ oneLine(info.started) ~ "\n");
  if (info.pid > 0)
    sb.put("pid = " ~ info.pid.to!string ~ "\n");
  foreach (app; info.webapps) {
    sb.put("\n[webapp " ~ oneLine(app.id) ~ "]\n");
    sb.put("uri = " ~ oneLine(app.uri) ~ "\n");
    sb.put("context = " ~ oneLine(app.context) ~ "\n");
    foreach (url; app.urls)
      sb.put("url = " ~ oneLine(url) ~ "\n");
  }
  return sb.data;
}

/**
 * 解析 `server.info` 文本。
 *
 * 宽容读者：空行、`;` / `#` 注释、`=` 两侧空格、未知键与未知分节一律忽略，坏值（端口 / pid 非
 * 数字）当作没写。这样以后加字段不会让旧版 basctl 读不出来。重复的 `id` 等键取最后一次。
 */
ServerInfo parseServerInfo(string text) {
  ServerInfo info;
  WebappInfo webapp;
  bool inServer, inWebapp;

  void flushWebapp() {
    if (!inWebapp)
      return;
    info.webapps ~= webapp;
    webapp = WebappInfo.init;
    inWebapp = false;
  }

  foreach (raw; text.split("\n")) {
    auto line = strip(raw);
    if (!line.length || line[0] == ';' || line[0] == '#')
      continue;
    if (line[0] == '[') {
      auto close = line.indexOf(']');
      if (close < 0)
        continue;
      auto head = strip(line[1 .. close]);
      flushWebapp();
      inServer = head == "server";
      if (head == "webapp" || head.startsWith("webapp ")) {
        webapp = WebappInfo.init;
        webapp.id = strip(head["webapp".length .. $]);
        inWebapp = true;
      }
      continue;
    }
    auto equals = line.indexOf('=');
    if (equals < 0)
      continue;
    auto key = strip(line[0 .. equals]).toLower;
    auto value = strip(line[equals + 1 .. $]);
    if (inServer) {
      switch (key) {
      case "id": info.id = value; break;
      case "engine": info.engine = value; break;
      case "http.port": info.httpPort = parsePort(value); break;
      case "started": info.started = value; break;
      case "pid": info.pid = parsePid(value); break;
      default: break;
      }
    } else if (inWebapp) {
      switch (key) {
      case "uri": webapp.uri = value; break;
      case "context": webapp.context = value; break;
      case "url": if (value.length && !webapp.urls.canFind(value)) webapp.urls ~= value; break;
      default: break;
      }
    }
  }
  flushWebapp();
  return info;
}

/** `servers/<instance>/server.info` 的路径。 */
string serverInfoPath(string basHome, string instance) {
  return buildPath(basHome, "servers", instance, "server.info");
}

/** 读一个显式路径的 `server.info`；文件缺失或读不到时为空（解析本身不抛）。 */
Nullable!ServerInfo readServerInfo(string path) {
  if (!exists(path))
    return Nullable!ServerInfo.init;
  try
    return nullable(parseServerInfo(readText(path)));
  catch (Exception)
    return Nullable!ServerInfo.init;
}

/** 读实例的运行信息；缺少 `id` 时补上目录名，读者总能拿到实例标识。 */
Nullable!ServerInfo readInstanceInfo(string basHome, string instance) {
  auto info = readServerInfo(serverInfoPath(basHome, instance));
  if (info.isNull)
    return Nullable!ServerInfo.init;
  auto value = info.get;
  if (!value.id.length)
    value.id = instance;
  return nullable(value);
}

/**
 * 原子写入：先写同目录临时文件再 `rename`，读者不会看到写了一半的文件（补写 pid 也整文件重写）。
 * 目标目录不存在时自动创建（实例目录可能还没建）。
 */
void writeServerInfo(string path, const ServerInfo info) {
  mkdirPrivate(dirName(path));
  auto tmp = path ~ ".tmp";
  write(tmp, renderServerInfo(info));
  rename(tmp, path);
}

/**
 * 写实例的运行信息。写入前的预留与确认存活后的补 pid 都走这里。
 */
void writeInstanceInfo(string basHome, string instance, const ServerInfo info) {
  writeServerInfo(serverInfoPath(basHome, instance), info);
}

/** 删除实例的运行信息（启动失败或停止之后）；不存在即无操作。 */
void removeInstanceInfo(string basHome, string instance) {
  auto path = serverInfoPath(basHome, instance);
  if (exists(path))
    remove(path);
}

/**
 * 实例记录的 pid（取自 `server.info`）。**不判断存活**——调用方要么自己看存活
 * （{@link liveInstancePid}），要么本来就是来看它死没死的。
 */
Nullable!int instancePid(string basHome, string instance) {
  auto info = readInstanceInfo(basHome, instance);
  if (!info.isNull && info.get.pid > 0)
    return nullable(info.get.pid);
  return Nullable!int.init;
}

/** 实例记录的 pid 且进程确实活着；否则为空（陈旧信息由调用方决定要不要清理）。 */
Nullable!int liveInstancePid(string basHome, string instance) {
  auto pid = instancePid(basHome, instance);
  if (pid.isNull || !processRunning(pid.get))
    return Nullable!int.init;
  return pid;
}

/**
 * 本机所有**活着**的实例运行信息：`servers/<name>/server.info` 里 pid 存活且端口已定的那些，
 * 按实例名排序（输出稳定）。
 *
 * 这是 setline 对账的输入——路由恒等于「此刻真实活着的实例」，pid 不在即视为不存在。陈旧信息
 * （进程已死）不在这里清理：清理是 `stop` / `status` 的事，对账只读。
 */
ServerInfo[] liveInstances(string basHome) {
  auto serversDir = buildPath(basHome, "servers");
  if (!exists(serversDir) || !isDir(serversDir))
    return [];

  string[] names;
  foreach (entry; dirEntries(serversDir, SpanMode.shallow)) {
    if (entry.isDir)
      names ~= baseName(entry.name);
  }
  names.sort();

  ServerInfo[] infos;
  foreach (name; names) {
    auto info = readInstanceInfo(basHome, name);
    if (info.isNull)
      continue;
    if (info.get.pid <= 0 || !processRunning(info.get.pid))
      continue;
    if (info.get.httpPort <= 0)
      continue;
    infos ~= info.get;
  }
  return infos;
}

/**
 * 本机时区的 ISO-8601 时间（`2026-10-07T10:12:33+08:00`），用于 `started`。
 * D 的 `%z` 不带冒号，这里自己拼，保证与文档里写的格式一致。
 */
string localIsoTimestamp(SysTime now) {
  auto offsetMinutes = now.utcOffset.total!"minutes";
  auto sign = offsetMinutes < 0 ? "-" : "+";
  auto magnitude = offsetMinutes < 0 ? -offsetMinutes : offsetMinutes;
  return format!"%04d-%02d-%02dT%02d:%02d:%02d%s%02d:%02d"(now.year, now.month, now.day,
      now.hour, now.minute, now.second, sign, magnitude / 60, magnitude % 60);
}

/** 折掉值里的换行与首尾空白：运行信息一行一个键，值里不能有换行。 */
private string oneLine(string value) {
  return strip(value).replace("\r", " ").replace("\n", " ");
}

/** 解析端口，非法值记 0（坏字段不该让整份运行信息读不出来）。 */
private ushort parsePort(string text) {
  try {
    auto port = strip(text).to!int;
    return port > 0 && port <= 65535 ? cast(ushort) port : 0;
  }
  catch (Exception)
    return 0;
}

/** 解析 pid，非法值记 0。 */
private int parsePid(string text) {
  try {
    auto pid = strip(text).to!int;
    return pid > 0 ? pid : 0;
  }
  catch (Exception)
    return 0;
}
