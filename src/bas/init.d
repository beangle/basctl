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
 * `bin/setenv.sh` 与 `conf/server.xml` 属用户配置，本命令不生成也不改动。
 */
module bas.init;

import bas.fsutil : setExecutable;

import std.conv : to;
import std.file : exists, getcwd, mkdirRecurse, write;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.stdio : stderr, writeln;
import std.string : startsWith, strip;

/** 内嵌的控制脚本，按安装顺序排列。 */
private immutable string[] scriptNames = ["env.sh", "bas.sh", "start.sh", "stop.sh", "restart.sh"];

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
  default:
    return "";
  }
}

/** `installScripts` 的结果：写入与保留的脚本数。 */
struct InitResult {
  int written;
  int kept;
}

/**
 * 把内嵌控制脚本铺到 `workdir/bin/`，并建好 `conf/`。
 *
 * 已存在的脚本默认保留，`force` 才覆盖；`dryRun` 只打印动作、不落盘。
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
      ~ (result.kept ? ", " ~ to!string(result.kept) ~ " kept" : ""));
  return 0;
}

/** 打印 `init` 用法到 stderr。 */
void initUsage() {
  stderr.writeln("Usage: basctl init [--force] [--dry-run] [workdir]");
  stderr.writeln("  Install the control scripts (env.sh, bas.sh, start.sh, stop.sh,");
  stderr.writeln("  restart.sh) into <workdir>/bin and create <workdir>/conf. Existing");
  stderr.writeln("  scripts are kept unless --force is given. <workdir> defaults to");
  stderr.writeln("  $BAS_HOME (or the current directory).");
}
