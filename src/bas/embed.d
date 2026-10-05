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
 * `basctl run`：嵌入式运行单个 webapp（war / Maven 坐标 / http url）。
 *
 * 不读 `conf/server.xml`：一个参数 `--engine=<type>-<version>`（如 `tomcat-11.0.25`、
 * `undertow-2.0.3.Final`）同时给出容器类型与版本；bas 引擎版本取 basctl 的默认值
 * {@link defaultBasVersion}（`--bas=` 可覆盖）。依赖集与 `start` 共用 `engines.ini`
 * （见 {@link bas.config.resolveEngineDeps}，这里没有 `<engine><jar>`，就用默认集）。
 *
 * 据此写出单应用 launch spec（`[app] entry` + `[engine] init = basctl make <type>-embed`），
 * 再前台 `jstart run` —— jstart 先跑 init 准备容器环境，随后 exec 容器进程；本命令等待
 * 其退出并返回同一退出码。
 */
module bas.embed;

import bas.artifact : isRemote;
import bas.config : Container, Engine, containerTypeOf, engineModeStandalone, resolveEngineDeps;
import bas.jstart : jstartCommand;
import bas.spec : engineInitCommand, renderLaunchSpec;

import std.array : join, split;
import std.file : getcwd, mkdirRecurse, write;
import std.path : absolutePath, buildPath, dirName;
import std.process : ProcessException, environment, spawnProcess, wait;
import std.stdio : stderr, stdout, writeln;
import std.string : indexOf, startsWith, strip;

/**
 * `run` 的 beangle-bas-engine 默认版本。
 *
 * 这是 basctl 为便捷运行维护的唯一默认值：只作用于 `run`（用 `--bas=` 覆盖）；
 * `conf/server.xml` 的多实例部署一律以 `<bas version>` 为准。
 */
enum defaultBasVersion = "0.14.0";

/** `<type>-<version>` 形式的嵌入式容器（如 `tomcat-11.0.25`）。 */
struct EngineRef {
  string typ;
  string version_;

  /** 解析 `tomcat-11.0.25` / `undertow-2.0.3.Final`；类型未知或缺少版本时返回空 `typ`。 */
  static EngineRef parse(string value) {
    auto s = strip(value);
    auto dash = s.indexOf('-');
    if (dash <= 0 || dash + 1 >= s.length)
      return EngineRef.init;
    auto typ = strip(s[0 .. dash]);
    if (typ != "tomcat" && typ != "undertow")
      return EngineRef.init;
    return EngineRef(typ, strip(s[dash + 1 .. $]));
  }
}

/** `basctl run` 的解析结果；`error` 非空表示参数有误。 */
struct RunOptions {
  EngineRef engine;
  string bas = defaultBasVersion;
  string base = "/tmp";
  string instance = "bas";
  string workdir;
  string local;
  string remote;
  string spec;
  bool help;
  bool offline;
  bool printOnly;
  string entry;
  string[] runtimeArgs;
  string[] appArgs;
  string error;
}

/** run 的 creator 类型与引擎依赖（`engines.ini` 默认集 + bas 默认版本）。 */
struct RunPlan {
  string containerType;
  string[] deps;
}

/** 由 `--engine` / `--bas` 推导 creator 类型与引擎依赖。 */
RunPlan planRun(RunOptions opts) {
  auto container = new Container;
  container.version_ = opts.bas;
  auto engine = new Engine(opts.engine.typ, opts.engine.typ, opts.engine.version_);
  engine.mode = engineModeStandalone;

  RunPlan plan;
  plan.containerType = containerTypeOf(engine);
  plan.deps = resolveEngineDeps(container, engine, plan.containerType);
  return plan;
}

/** `basctl run [options] <app> [app args...]`：生成 spec 后前台委托 jstart。 */
int runEmbedded(string[] args) {
  auto opts = parseRunArgs(args);
  if (opts.help) {
    runUsage();
    return 0;
  }
  if (opts.error.length) {
    stderr.writeln(opts.error);
    runUsage();
    return 1;
  }
  if (!opts.entry.length) {
    runUsage();
    return 1;
  }

  auto plan = planRun(opts);
  auto base = absolutePath(opts.base);
  auto workdir = opts.workdir.length ? absolutePath(opts.workdir) : getcwd();
  auto spec = opts.spec.length ? absolutePath(opts.spec) : buildPath(base, opts.instance, "run.jstart");

  mkdirRecurse(dirName(spec));
  write(spec, renderLaunchSpec(base, opts.instance, workdir, engineInitCommand(plan.containerType),
      plan.deps, opts.runtimeArgs, opts.appArgs, [], warTarget(opts.entry)));
  writeln("spec: " ~ spec);

  auto jstartArgs = commonJstartArgs(opts);
  if (opts.printOnly) {
    writeln(([jstartCommand()] ~ jstartArgs ~ ["run", spec]).join(" "));
    return 0;
  }
  return execJstart(jstartArgs ~ ["run", spec]);
}

/** 打印 `basctl run` 的用法到 stderr。 */
void runUsage() {
  stderr.writeln("Usage: basctl run [options] <app> [app args...]");
  stderr.writeln("  <app>                         war / 解压目录，g:a:v（按 war），或 http(s) url");
  stderr.writeln("Options:");
  stderr.writeln("  --engine=<type>-<version>     Embedded container, e.g. tomcat-11.0.25 (required)");
  stderr.writeln("  --bas=<version>               beangle-bas-engine version (default " ~ defaultBasVersion ~ ")");
  stderr.writeln("  --base=<dir>                  Base root of the component (default /tmp)");
  stderr.writeln("  --instance=<name>             Component directory name (default bas)");
  stderr.writeln("  --workdir=<dir>               Working directory (default: current dir)");
  stderr.writeln("  --local=<dir>                 Local repository (default: $M2_REPO)");
  stderr.writeln("  --remote=<urls>               Upstream repositories (default: $M2_REMOTE_REPO)");
  stderr.writeln("  --spec=<file>                 Spec path (default <base>/<instance>/run.jstart)");
  stderr.writeln("  --offline                     Resolve from the local repository only");
  stderr.writeln("  --print                       Write the spec and print the jstart command only");
  stderr.writeln("  -D<k>=<v>, -X<opt>            JVM options -> [runtime]");
  stderr.writeln("  --<option>                    Application options (e.g. --port=8080) -> [args]");
}

/** 解析 `basctl run` 的参数；顺序无关，出错时写 `error` 而不抛异常。 */
RunOptions parseRunArgs(string[] args) {
  RunOptions opts;
  foreach (arg; args) {
    if (arg.startsWith("--engine=")) {
      auto raw = strip(arg["--engine=".length .. $]);
      opts.engine = EngineRef.parse(raw);
      if (!opts.engine.typ.length)
        opts.error = "Invalid --engine " ~ raw ~ ", expected <type>-<version> (e.g. tomcat-11.0.25).";
      continue;
    }
    if (assignValue(arg, "--bas=", opts.bas))
      continue;
    if (assignValue(arg, "--base=", opts.base))
      continue;
    if (assignValue(arg, "--instance=", opts.instance))
      continue;
    if (assignValue(arg, "--workdir=", opts.workdir))
      continue;
    if (assignValue(arg, "--local=", opts.local))
      continue;
    if (assignValue(arg, "--remote=", opts.remote))
      continue;
    if (assignValue(arg, "--spec=", opts.spec))
      continue;
    if (arg == "--help" || arg == "-h") {
      opts.help = true;
      continue;
    }
    if (arg == "--offline") {
      opts.offline = true;
      continue;
    }
    if (arg == "--print") {
      opts.printOnly = true;
      continue;
    }
    if (arg.startsWith("-D") || arg.startsWith("-X")) {
      opts.runtimeArgs ~= arg;
      continue;
    }
    if (arg.startsWith("-")) {
      opts.appArgs ~= arg;
      continue;
    }
    if (!opts.entry.length)
      opts.entry = arg;
    else
      opts.appArgs ~= arg;
  }

  if (!opts.error.length && !opts.engine.typ.length)
    opts.error = "Missing --engine=<type>-<version> (e.g. tomcat-11.0.25).";
  else if (!opts.error.length) {
    if (!opts.base.length)
      opts.error = "--base must not be empty.";
    else if (!isSafeInstance(opts.instance))
      opts.error = "Invalid --instance " ~ opts.instance
        ~ ": expected a single path segment of [A-Za-z0-9._-].";
  }
  return opts;
}

/** jstart 的 `[app] instance` 限定为单个安全路径段。 */
bool isSafeInstance(string name) {
  if (!name.length || name == "." || name == "..")
    return false;
  foreach (c; name) {
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
        || c == '.' || c == '_' || c == '-')
      continue;
    return false;
  }
  return true;
}

/**
 * 3 段 gav（`group:artifact:version`）在 run 语境下按 war 解析，补成
 * `group:artifact:war:version`；url 与本地路径原样返回。
 */
string warTarget(string entry) {
  if (isRemote(entry))
    return entry;
  int colons;
  foreach (c; entry)
    if (c == ':')
      colons++;
  if (colons != 2)
    return entry;
  auto parts = entry.split(":");
  return parts[0] ~ ":" ~ parts[1] ~ ":war:" ~ parts[2];
}

/**
 * 透传给 jstart 的全局参数：本地仓库与上游。
 *
 * `--local` / `--remote` 优先；缺省沿用 `env.sh` 导出的 `M2_REPO` /
 * `M2_REMOTE_REPO`，两者都为空时不传，交给 jstart 的内置默认。
 */
string[] commonJstartArgs(RunOptions opts) @trusted {
  string[] args;
  auto local = opts.local.length ? opts.local : strip(environment.get("M2_REPO", ""));
  if (local.length)
    args ~= "--local=" ~ local;
  auto remote = opts.remote.length ? opts.remote : strip(environment.get("M2_REMOTE_REPO", ""));
  if (remote.length)
    args ~= "--remote=" ~ remote;
  if (opts.offline)
    args ~= "--offline";
  return args;
}

/**
 * 前台运行 `jstart run <spec>`：继承当前 stdio，等待进程退出并返回其退出码。
 * jstart 会把自己 exec 成容器进程，因此这里等待的就是最终服务进程。
 */
int execJstart(string[] args) {
  stdout.flush();
  try {
    return wait(spawnProcess(jstartCommand() ~ args));
  } catch (ProcessException) {
    stderr.writeln("Cannot run " ~ jstartCommand() ~ ", install jstart or set bas_jstart to its path.");
    return 1;
  }
}

/** `--key=value` 形式：匹配时写入 `target` 并返回 true。 */
private bool assignValue(string arg, string prefix, ref string target) {
  if (!arg.startsWith(prefix))
    return false;
  target = arg[prefix.length .. $];
  return true;
}
