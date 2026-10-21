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
 * `init`：把控制脚本铺到 `<workdir>/bin/`，初始化一个 bas 组件目录。
 *
 * 脚本内嵌在本二进制里（`resources/bas/bin/`），随 basctl 版本发布，避免发行包与
 * basctl 版本错配。已存在的脚本默认保留（用户可能改过），`--force` 才覆盖；
 * `conf/basctl.conf` 只在不存在时生成一份带注释、字段留空的模板（0600），已有文件
 * 一律保留，`--force` 也不覆盖。`bin/setenv.sh` 与 `conf/server.xml` 属用户配置，
 * 本命令不生成。
 */
module bas.init;

import bas.fsutil : setExecutable, setPrivateFile;
import bas.remote : remoteConfFileName;

import std.conv : to;
import std.file : exists, getcwd, mkdirRecurse, write;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.stdio : stderr, writeln;
import std.string : startsWith, strip;

/** 内嵌的控制脚本，按安装顺序排列。 */
private immutable string[] scriptNames =
  ["env.sh", "bas.sh", "start.sh", "stop.sh", "restart.sh", "start-agent.sh", "stop-agent.sh"];

/** 内嵌的 `conf/basctl.conf` 注释模板；三项留空，不会意外启用远端。 */
private enum remoteConfTemplate = import("bas/init/basctl.conf");

/** 取某个内嵌脚本的内容（相对 `resources/` 的路径）。 */
string scriptBody(string name) {
  switch (name) {
  case "env.sh":
    return import("bas/bin/env.sh");
  case "bas.sh":
    return import("bas/bin/bas.sh");
  case "start.sh":
    return import("bas/bin/start.sh");
  case "stop.sh":
    return import("bas/bin/stop.sh");
  case "restart.sh":
    return import("bas/bin/restart.sh");
  case "start-agent.sh":
    return import("bas/bin/start-agent.sh");
  case "stop-agent.sh":
    return import("bas/bin/stop-agent.sh");
  default:
    return "";
  }
}

/** `installScripts` 的结果：脚本与 `basctl.conf` 的写入 / 保留情况。 */
struct InitResult {
  int written;
  int kept;
  bool confWritten;
  bool confKept;
}

/**
 * 把内嵌控制脚本铺到 `workdir/bin/`，建好 `conf/`，并在配置不存在时生成注释模板。
 *
 * 已存在的脚本默认保留，`force` 才覆盖；`basctl.conf` 一旦存在就永不覆盖。
 * `dryRun` 只打印动作、不落盘。
 */
InitResult installScripts(string workdir, bool force = false, bool dryRun = false) {
  InitResult result;
  auto binDir = buildPath(workdir, "bin");
  if (!dryRun) {
    mkdirRecurse(binDir);
    mkdirRecurse(buildPath(workdir, "conf"));
  }
  foreach (name; scriptNames) {
    auto target = buildPath(binDir, name);
    if (exists(target) && !force) {
      writeln("keep " ~ target ~ " (exists; use --force to overwrite)");
      result.kept++;
      continue;
    }
    if (dryRun) {
      writeln("would write " ~ target);
    } else {
      write(target, scriptBody(name));
      setExecutable(target);
      writeln("write " ~ target);
    }
    result.written++;
  }

  auto conf = buildPath(workdir, "conf", remoteConfFileName);
  if (exists(conf)) {
    writeln("keep " ~ conf ~ " (exists; user configuration is never overwritten)");
    result.confKept = true;
  } else if (dryRun) {
    writeln("would write " ~ conf);
    result.confWritten = true;
  } else {
    write(conf, remoteConfTemplate);
    setPrivateFile(conf);
    writeln("write " ~ conf);
    result.confWritten = true;
  }
  return result;
}

/** `init [--force] [--dry-run] [workdir]`：铺设控制脚本。 */
int runInit(string[] args) {
  bool force, dryRun;
  string workdir;
  foreach (arg; args) {
    if (arg == "--force" || arg == "-f") {
      force = true;
    } else if (arg == "--dry-run" || arg == "-n") {
      dryRun = true;
    } else if (arg == "--help" || arg == "-h") {
      initUsage();
      return 0;
    } else if (arg.startsWith("-")) {
      stderr.writeln("Unknown option: " ~ arg);
      initUsage();
      return 1;
    } else if (!workdir.length) {
      workdir = arg;
    } else {
      stderr.writeln("Too many arguments: " ~ arg);
      initUsage();
      return 1;
    }
  }

  if (!workdir.length) {
    auto fromEnv = strip(environment.get("BAS_HOME", ""));
    workdir = fromEnv.length ? fromEnv : getcwd();
  }
  workdir = absolutePath(workdir);

  auto result = installScripts(workdir, force, dryRun);
  writeln("initialized " ~ workdir ~ ": " ~ to!string(result.written)
      ~ (dryRun ? " scripts to write" : " scripts written")
      ~ (result.kept ? ", " ~ to!string(result.kept) ~ " kept" : "")
      ~ (result.confWritten ? (dryRun ? ", conf/" ~ remoteConfFileName ~ " to write"
                                     : ", conf/" ~ remoteConfFileName ~ " written") : "")
      ~ (result.confKept ? ", conf/" ~ remoteConfFileName ~ " kept" : ""));
  return 0;
}

/** 打印 `init` 用法到 stderr。 */
void initUsage() {
  stderr.writeln("Usage: basctl init [--force] [--dry-run] [workdir]");
  stderr.writeln("  Install the control scripts (env.sh, bas.sh, start.sh, stop.sh,");
  stderr.writeln("  restart.sh, start-agent.sh, stop-agent.sh) into <workdir>/bin and create");
  stderr.writeln("  <workdir>/conf. When");
  stderr.writeln("  conf/basctl.conf is absent, write a commented 0600 template with empty");
  stderr.writeln("  remote fields; an existing file is never overwritten. Existing scripts");
  stderr.writeln("  are kept unless --force is given. <workdir> defaults to $BAS_HOME (or");
  stderr.writeln("  the current directory).");
}
