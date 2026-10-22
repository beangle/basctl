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
 * 地址、Profile 与凭证都取自 `conf/basctl.conf` 的 `[remote]` 段；请求只用
 * `Authorization: Bearer <profile>:<Profile.key>` 鉴权，不再发送可伪造的 `ip:` 头，也不再读取
 * `bas_remote_*` 环境变量。旧配置备份为 `conf/server_old.xml`；拉取失败时保留
 * 现有配置不动。
 */
module bas.pull;

import bas.download : curlDownload;
import bas.remote : RemoteConfig, bearerCredential, loadRemoteConf, remoteConfPath, serverConfigUrl,
  validateRemoteConf;

import std.file : exists, getcwd, mkdirRecurse, rename;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.stdio : stderr, stdout, write, writeln;
import std.string : startsWith, strip;

/** `pull [--file=<basctl.conf>] [--if-configured] [workdir]`：下载并替换 `<workdir>/conf/server.xml`。 */
int runPull(string[] args) {
  string confFile;
  string workdir;
  bool ifConfigured;
  foreach (arg; args) {
    if (arg.startsWith("--file=")) {
      confFile = strip(arg["--file=".length .. $]);
    } else if (arg == "--if-configured") {
      ifConfigured = true;
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

  if (!workdir.length) {
    auto fromEnv = strip(environment.get("BAS_HOME", ""));
    workdir = fromEnv.length ? fromEnv : getcwd();
  }
  workdir = absolutePath(workdir);

  if (!confFile.length)
    confFile = remoteConfPath(workdir);
  RemoteConfig remote;
  try {
    remote = loadRemoteConf(confFile);
    if (!remote.complete) {
      if (ifConfigured && !remote.configured)
        return 0;
      stderr.writeln("basagent pull: warning: remote is not configured in " ~ confFile
          ~ "; server.xml was not refreshed.");
      return 0;
    }
    validateRemoteConf(remote, confFile);
  } catch (Exception e) {
    stderr.writeln("basagent pull: " ~ e.msg);
    return 1;
  }

  auto url = serverConfigUrl(remote);
  write("fetching " ~ url ~ "...");
  stdout.flush();

  auto confDir = buildPath(workdir, "conf");
  mkdirRecurse(confDir);
  auto newer = buildPath(confDir, "server_newer.xml");
  if (!curlDownload(url, newer, ["Authorization: Bearer " ~ bearerCredential(remote)],
      true, 4 * 1024 * 1024)) {
    writeln(" failed");
    return 1;
  }

  auto current = buildPath(confDir, "server.xml");
  if (exists(current)) {
    rename(current, buildPath(confDir, "server_old.xml"));
  }
  rename(newer, current);
  writeln(" updated");
  return 0;
}

/** 打印 `pull` 用法到 stderr。 */
void pullUsage() {
  stderr.writeln("Usage: basagent pull [--file=<basctl.conf>] [--if-configured] [workdir]");
  stderr.writeln("  Fetch <remote.url>/api/bashub/config/<remote.profile>/server into <workdir>/conf,");
  stderr.writeln("  authenticating with Bearer <remote.profile>:<remote.token> from");
  stderr.writeln("  <workdir>/conf/basctl.conf. The old");
  stderr.writeln("  file is backed up as server_old.xml. <workdir> defaults to $BAS_HOME (or the");
  stderr.writeln("  current directory). --if-configured exits silently when all remote fields");
  stderr.writeln("  are empty (the generated template uses this mode).");
}
