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
 * 本机 `jstart` 命令的封装（Scala `org.beangle.sas.tool.Jstart`）。
 *
 * 构件解析/下载交给 jstart：
 *  - `jstart resolve <target>`：取得目标（gav / 本地 war / url）并补齐依赖，回显本地绝对路径；
 *  - `jstart fetch <target>`：只取回一个构件（gav / url），回显本地绝对路径。
 *
 * `--remote=` 是正式版上游，`--snapshot-remote=` 是开发版上游（两者独立）；读取受保护仓库的
 * 令牌按 jstart 的约定通过子进程环境变量 `micdn_token` 传递。命令位置可用 `sas_jstart` 覆盖。
 */
module bas.jstart;

import bas.config : Repository, SnapshotRepo;

import std.array : join, split;
import std.conv : to;
import std.process : Config, execute, environment;
import std.stdio : stderr, writeln;
import std.string : empty, strip;
import std.typecons : Nullable, nullable;

/** jstart 可执行文件；缺省 `jstart`，可用 `sas_jstart` 指定其它路径。 */
string jstartCommand() {
  auto cmd = environment.get("sas_jstart", "");
  return strip(cmd).length ? strip(cmd) : "jstart";
}

/** resolve：下载目标并补齐依赖，返回本地绝对路径。 */
Nullable!string resolve(string target, Repository repo) {
  return exec("resolve", target, repo.local, repo.remotes, repo.token, false, []);
}

/** resolve（开发版）：未配置上游时以 `--offline` 只使用本地已有构件。 */
Nullable!string resolve(string target, SnapshotRepo repo) {
  return exec("resolve", target, repo.local, [], repo.token, repo.remotes.length == 0, repo.remotes);
}

/** fetch：只取回一个构件，返回本地绝对路径。 */
Nullable!string fetch(string target, Repository repo) {
  return exec("fetch", target, repo.local, repo.remotes, repo.token, false, []);
}

/** fetch（开发版）：未配置上游时以 `--offline` 只使用本地已有构件。 */
Nullable!string fetch(string target, SnapshotRepo repo) {
  return exec("fetch", target, repo.local, [], repo.token, repo.remotes.length == 0, repo.remotes);
}

/** fetch：显式指定本地仓库 / 上游 / 令牌。 */
Nullable!string fetch(string target, Nullable!string local, const(string)[] remotes, Nullable!string token) {
  return exec("fetch", target, local, remotes, token, false, []);
}

/** resolve：显式指定本地仓库 / 上游 / 令牌。 */
Nullable!string resolve(string target, Nullable!string local, const(string)[] remotes, Nullable!string token) {
  return exec("resolve", target, local, remotes, token, false, []);
}

private Nullable!string exec(string sub, string target, Nullable!string local, const(string)[] remotes,
    Nullable!string token, bool offline, const(string)[] snapshotRemotes) {
  auto args = buildArgs(jstartCommand(), sub, target, local, remotes, offline, snapshotRemotes);

  bool hadToken;
  string previousToken;
  if (!token.isNull) {
    hadToken = "micdn_token" in environment;
    if (hadToken)
      previousToken = environment.get("micdn_token");
    environment["micdn_token"] = token.get;
  }
  scope (exit) {
    if (!token.isNull) {
      if (hadToken)
        environment["micdn_token"] = previousToken;
      else
        environment.remove("micdn_token");
    }
  }

  import std.process : ProcessException;
  import std.typecons : Tuple;

  Tuple!(int, "status", string, "output") result;
  try
    result = execute(args, null, Config.stderrPassThrough);
  catch (ProcessException) {
    stderr.writeln("Cannot run " ~ jstartCommand() ~ ", install jstart or set sas_jstart to its path.");
    return Nullable!string.init;
  }

  if (result.status != 0) {
    stderr.writeln(jstartCommand() ~ " " ~ sub ~ " " ~ target ~ " failed with exit code " ~ result.status.to!string);
    return Nullable!string.init;
  }
  return lastLine(result.output);
}

/** 拼出 jstart 命令行；`resolve`/`fetch` 共用同一套参数。 */
string[] buildArgs(string command, string sub, string target, Nullable!string local, const(string)[] remotes,
    bool offline, const(string)[] snapshotRemotes) {
  string[] args = [command, sub, target];
  if (!local.isNull && strip(local.get).length)
    args ~= "--local=" ~ strip(local.get);
  if (remotes.length)
    args ~= "--remote=" ~ remotes.join(",");
  if (snapshotRemotes.length)
    args ~= "--snapshot-remote=" ~ snapshotRemotes.join(",");
  if (offline)
    args ~= "--offline";
  return args;
}

/** 结果路径是 stdout 的最后一个非空行（jstart 可能在其前打印进度）。 */
private Nullable!string lastLine(string output) {
  auto lines = output.split("\n");
  for (auto i = lines.length; i > 0; --i) {
    auto line = strip(lines[i - 1]);
    if (line.length)
      return nullable(line);
  }
  return Nullable!string.init;
}

@("build args keeps official and snapshot remotes separate") unittest {
  import std.typecons : nullable;

  auto args = buildArgs("jstart", "resolve", "g:a:1", nullable("/repo"), ["https://a", "https://b"], false, []);
  assert(args == ["jstart", "resolve", "g:a:1", "--local=/repo", "--remote=https://a,https://b"]);

  auto snap = buildArgs("jstart", "fetch", "g:a:1-SNAPSHOT", Nullable!string.init, [], true, ["https://snap"]);
  assert(snap == ["jstart", "fetch", "g:a:1-SNAPSHOT", "--snapshot-remote=https://snap", "--offline"]);
}

@("last line skips trailing blanks") unittest {
  assert(lastLine("/repo/g/a/1/a-1.jar\n\n").get == "/repo/g/a/1/a-1.jar");
  assert(lastLine("").isNull);
}
