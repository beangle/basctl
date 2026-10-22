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
 * 本机 `jstart` 命令的封装。
 *
 * 构件解析/下载交给 jstart：
 *  - `jstart resolve <target>`：取得目标（gav / 本地 war / url）并补齐依赖，回显本地绝对路径；
 *  - `jstart fetch <target>`：只取回一个构件（gav / url），回显本地绝对路径。
 *
 * `--remote=` 是正式版上游，`--snapshot-remote=` 是开发版上游（两者独立）；每个仓库写作
 * `[token@]url`，不再读取或改写环境变量。命令位置可用 `beangle_jstart` 覆盖。
 */
module bas.jstart;

import bas.config : Repository, SnapshotRepo;

import std.array : join, split;
import std.conv : to;
import std.process : Config, execute, environment;
import std.stdio : stderr, writeln;
import std.string : empty, strip;
import std.typecons : Nullable, nullable;

/** 覆盖 jstart 可执行文件位置的环境变量名；命令相关的覆盖一律用 `beangle_<command>`。 */
enum jstartEnvVar = "beangle_jstart";

/** jstart 可执行文件；缺省 `jstart`，可用 {@link jstartEnvVar} 指定其它路径。 */
string jstartCommand() {
  auto cmd = environment.get(jstartEnvVar, "");
  return strip(cmd).length ? strip(cmd) : "jstart";
}

/** resolve：下载目标并补齐依赖，返回本地绝对路径。 */
Nullable!string resolve(string target, Repository repo) {
  return exec("resolve", target, repo.local, repo.repoSpecs, false, []);
}

/** resolve（开发版）：未配置上游时以 `--offline` 只使用本地已有构件。 */
Nullable!string resolve(string target, SnapshotRepo repo) {
  return exec("resolve", target, repo.local, [], repo.remotes.length == 0, repo.repoSpecs);
}

/** fetch：只取回一个构件，返回本地绝对路径。 */
Nullable!string fetch(string target, Repository repo) {
  return exec("fetch", target, repo.local, repo.repoSpecs, false, []);
}

/**
 * fetch（开发版）：未配置上游时以 `--offline` 只使用本地已有构件。
 *
 * SNAPSHOT 的上游存在与否是开发版常态，调用方通常还要与 `BAS_HOME/webapps`
 * 下的本地覆盖比较，因此默认静默 jstart 的下载失败与告警。
 */
Nullable!string fetch(string target, SnapshotRepo repo, bool quiet = true) {
  return exec("fetch", target, repo.local, [], repo.remotes.length == 0, repo.repoSpecs, quiet);
}

private Nullable!string exec(string sub, string target, Nullable!string local, const(string)[] remotes,
    bool offline, const(string)[] snapshotRemotes, bool quiet = false) {
  auto args = buildArgs(jstartCommand(), sub, target, local, remotes, offline, snapshotRemotes, quiet);

  import std.process : ProcessException;
  import std.typecons : Tuple;

  Tuple!(int, "status", string, "output") result;
  try
    result = quiet ? execute(args, null) : execute(args, null, Config.stderrPassThrough);
  catch (ProcessException) {
    if (!quiet)
      stderr.writeln("Cannot run " ~ jstartCommand() ~ ", install jstart or set " ~ jstartEnvVar
          ~ " to its path.");
    return Nullable!string.init;
  }

  if (result.status != 0) {
    if (!quiet)
      stderr.writeln(jstartCommand() ~ " " ~ sub ~ " " ~ target ~ " failed with exit code "
          ~ result.status.to!string);
    return Nullable!string.init;
  }
  return lastLine(result.output);
}

/** 拼出 jstart 命令行；`resolve`/`fetch` 共用同一套参数。 */
string[] buildArgs(string command, string sub, string target, Nullable!string local, const(string)[] remotes,
    bool offline, const(string)[] snapshotRemotes, bool quiet = false) {
  string[] args = [command, sub, target];
  if (!local.isNull && strip(local.get).length)
    args ~= "--local=" ~ strip(local.get);
  if (remotes.length) {
    args ~= "--remote=" ~ remotes.join(",");
  }
  if (snapshotRemotes.length) {
    args ~= "--snapshot-remote=" ~ snapshotRemotes.join(",");
  }
  if (offline)
    args ~= "--offline";
  if (quiet)
    args ~= "--quiet";
  return args;
}

/** 结果路径是 stdout 的最后一个非空行（jstart 可能在其前打印进度）。 */
Nullable!string lastLine(string output) {
  auto lines = output.split("\n");
  for (auto i = lines.length; i > 0; --i) {
    auto line = strip(lines[i - 1]);
    if (line.length)
      return nullable(line);
  }
  return Nullable!string.init;
}
