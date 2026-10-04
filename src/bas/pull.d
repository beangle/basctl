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
 * `pull`：从控制端拉取 `conf/server.xml`。
 *
 * remote 缺省取环境变量 `bas_remote_url`（由发行包的 `bin/setenv.sh` 提供），请求带
 * `ip:<本机地址>` 头，服务端据此下发该机器对应的配置。旧配置备份为
 * `conf/server_old.xml`；拉取失败时保留现有配置不动。
 */
module bas.pull;

import bas.download : curlDownload;
import bas.net : localAddresses;

import std.file : exists, getcwd, mkdirRecurse, rename;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.stdio : stderr, writeln;
import std.string : endsWith, startsWith, strip;

/** `pull [--remote=<url>] [workdir]`：下载并替换 `<workdir>/conf/server.xml`。 */
int runPull(string[] args) {
  string remote;
  string workdir;
  foreach (arg; args) {
    if (arg.startsWith("--remote=")) {
      remote = strip(arg["--remote=".length .. $]);
    } else if (arg == "--help" || arg == "-h") {
      pullUsage();
      return 0;
    } else if (arg.startsWith("-")) {
      stderr.writeln("Unknown option: " ~ arg);
      pullUsage();
      return 1;
    } else if (!workdir.length) {
      workdir = arg;
    } else {
      stderr.writeln("Too many arguments: " ~ arg);
      pullUsage();
      return 1;
    }
  }

  if (!remote.length)
    remote = strip(environment.get("bas_remote_url", ""));
  if (!remote.length) {
    stderr.writeln("define bas_remote_url in bin/setenv.sh (or pass --remote=<url>)");
    return 1;
  }

  if (!workdir.length) {
    auto fromEnv = strip(environment.get("BAS_HOME", ""));
    workdir = fromEnv.length ? fromEnv : getcwd();
  }
  workdir = absolutePath(workdir);

  auto url = serverXmlUrl(remote);
  writeln("fetching " ~ url ~ "...");

  auto confDir = buildPath(workdir, "conf");
  mkdirRecurse(confDir);
  auto newer = buildPath(confDir, "server_newer.xml");
  auto ip = ipHeader(localAddresses());
  if (!curlDownload(url, newer, ip.length ? ["ip:" ~ ip] : null)) {
    stderr.writeln("cannot get " ~ url);
    return 1;
  }

  auto current = buildPath(confDir, "server.xml");
  if (exists(current)) {
    rename(current, buildPath(confDir, "server_old.xml"));
    writeln("rename server.xml to server_old.xml.");
  }
  rename(newer, current);
  writeln("conf/server.xml was updated.");
  return 0;
}

/** 控制端 server.xml 的 URL：`<remote>/config/server.xml`（容忍结尾斜杠）。 */
string serverXmlUrl(string remote) {
  auto base = strip(remote);
  while (base.endsWith("/"))
    base = base[0 .. $ - 1];
  return base ~ "/config/server.xml";
}

/** `ip` 请求头的取值：本机非回环 IPv4，空格分隔；只有回环时返回空串。 */
string ipHeader(const(string)[] addresses) {
  string result;
  foreach (address; addresses) {
    if (address == "127.0.0.1")
      continue;
    if (result.length)
      result ~= " ";
    result ~= address;
  }
  return result;
}

/** 打印 `pull` 用法到 stderr。 */
void pullUsage() {
  stderr.writeln("Usage: basctl pull [--remote=<url>] [workdir]");
  stderr.writeln("  Fetch <remote>/config/server.xml into <workdir>/conf, backing up the old");
  stderr.writeln("  file as server_old.xml. <url> defaults to $bas_remote_url, <workdir> to");
  stderr.writeln("  $BAS_HOME (or the current directory).");
}
