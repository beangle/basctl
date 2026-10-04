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
 * 不读 `conf/server.xml`：把目标写成一份单应用 launch spec（`[app] entry` +
 * `[engine] init = basctl make <tomcat|undertow>-embed` + 容器依赖），再前台
 * `jstart run` —— jstart 先跑 init 准备容器环境，随后 exec 容器进程，本命令等待
 * 其退出并返回同一退出码。
 *
 * 与多实例模式的差别只有输入来源：`start` 从 `conf/server.xml` 取引擎版本与实例
 * 清单，`run` 用 basctl 内置的缺省版本（可用 `bas_*_version` 环境变量覆盖），并固定
 * 一个组件目录（`--base` / `--instance`，缺省 `/tmp/sas`）。两者的 spec 渲染与
 * `make <type>` 回调完全共用（见 {@link bas.spec}）。
 */
module bas.embed;

import bas.artifact : isRemote;
import bas.jstart : jstartCommand;
import bas.spec : engineInitCommand, renderLaunchSpec;

import std.array : join, split;
import std.file : getcwd, mkdirRecurse, write;
import std.path : absolutePath, buildPath, dirName;
import std.process : ProcessException, environment, spawnProcess, wait;
import std.stdio : stderr, stdout, writeln;
import std.string : startsWith, strip;

/** 嵌入式运行构件的缺省版本；每项可用 `bas_*_version` 环境变量覆盖。 */
struct EmbedVersions {
  string engine = "0.13.16";
  string scala = "3.9.0";
  string commons = "6.3.7";
  string slf4j = "2.0.19";
  string logback = "1.6.3";
  string tomcat = "11.0.26";
  string undertow = "2.4.3.Final";
  string undertowEe = "2.0.2.Final";
}

/** `basctl run` 的解析结果；`error` 非空表示参数有误。 */
struct RunOptions {
  string engine = "tomcat";
  string base = "/tmp";
  string instance = "sas";
  string workdir;
  string local;
  string remote;
  string spec;
  bool offline;
  bool printOnly;
  string entry;
  string[] runtimeArgs;
  string[] appArgs;
  string error;
}

/** `basctl run [options] <app> [app args...]`：生成 spec 后前台委托 jstart。 */
int runEmbedded(string[] args) {
  auto opts = parseRunArgs(args);
  if (opts.error.length) {
    stderr.writeln(opts.error);
    runUsage();
    return 1;
  }
  if (!opts.entry.length) {
    runUsage();
    return 1;
  }

  auto containerType = opts.engine == "undertow" ? "undertow-embed" : "tomcat-embed";
  auto base = absolutePath(opts.base);
  auto workdir = opts.workdir.length ? absolutePath(opts.workdir) : getcwd();
  auto spec = opts.spec.length ? absolutePath(opts.spec) : buildPath(base, opts.instance, "run.jstart");

  mkdirRecurse(dirName(spec));
  write(spec, renderLaunchSpec(base, opts.instance, workdir, engineInitCommand(containerType),
      embedEngineDeps(opts.engine, embedVersions()), opts.runtimeArgs, opts.appArgs, [],
      warTarget(opts.entry)));
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
  stderr.writeln("  --engine=<tomcat|undertow>    Embedded container (default tomcat)");
  stderr.writeln("  --base=<dir>                  Base root of the component (default /tmp)");
  stderr.writeln("  --instance=<name>             Component directory name (default sas)");
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
    if (assignValue(arg, "--engine=", opts.engine))
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

  if (opts.engine != "tomcat" && opts.engine != "undertow")
    opts.error = "Unknown engine " ~ opts.engine ~ ", expected tomcat or undertow.";
  else if (!opts.base.length)
    opts.error = "--base must not be empty.";
  else if (!isSafeInstance(opts.instance))
    opts.error = "Invalid --instance " ~ opts.instance
      ~ ": expected a single path segment of [A-Za-z0-9._-].";
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

/** 嵌入式运行的 `[engine]` 依赖：引擎 jar + scala / 日志 + 选定的容器 jar。 */
string[] embedEngineDeps(string engine, EmbedVersions v) {
  string[] deps = [
    "org.beangle.sas:beangle-sas-engine:" ~ v.engine,
    "org.scala-lang:scala-library:" ~ v.scala,
    "org.scala-lang:scala3-library_3:" ~ v.scala,
    "org.beangle.commons:beangle-commons:" ~ v.commons,
    "org.slf4j:slf4j-api:" ~ v.slf4j,
    "org.slf4j:jul-to-slf4j:" ~ v.slf4j,
    "ch.qos.logback:logback-core:" ~ v.logback,
    "ch.qos.logback:logback-classic:" ~ v.logback,
  ];
  if (engine == "undertow")
    deps ~= undertowDeps(v);
  else
    deps ~= [
      "org.apache.tomcat.embed:tomcat-embed-core:" ~ v.tomcat,
      "org.apache.tomcat.embed:tomcat-embed-websocket:" ~ v.tomcat,
    ];
  return deps;
}

/**
 * 嵌入式 undertow 的容器依赖。jstart 不解析传递依赖，必须写全；版本跟随
 * `EmbedVersions`（与当前发布版引擎的编译期依赖一致），升级引擎时同步调整。
 */
string[] undertowDeps(EmbedVersions v) {
  return [
    "io.undertow:undertow-core:" ~ v.undertow,
    "io.undertow.ee:undertow-servlet:" ~ v.undertowEe,
    "io.undertow.ee:undertow-websockets:" ~ v.undertowEe,
    "org.jboss.logging:jboss-logging:3.6.3.Final",
    "org.jboss.threads:jboss-threads:3.9.2",
    "org.jboss.xnio:xnio-api:3.8.16.Final",
    "org.jboss.xnio:xnio-nio:3.8.16.Final",
    "jakarta.annotation:jakarta.annotation-api:2.1.1",
    "jakarta.servlet:jakarta.servlet-api:6.1.0",
    "jakarta.websocket:jakarta.websocket-api:2.2.0",
    "jakarta.websocket:jakarta.websocket-client-api:2.2.0",
    "org.wildfly.client:wildfly-client-config:1.0.1.Final",
    "org.wildfly.common:wildfly-common:2.0.1",
    "io.smallrye.common:smallrye-common-annotation:2.14.0",
    "io.smallrye.common:smallrye-common-constraint:2.12.0",
    "io.smallrye.common:smallrye-common-cpu:2.14.0",
    "io.smallrye.common:smallrye-common-expression:2.4.0",
    "io.smallrye.common:smallrye-common-function:2.14.0",
    "io.smallrye.common:smallrye-common-net:2.12.0",
    "io.smallrye.common:smallrye-common-os:2.4.0",
    "io.smallrye.common:smallrye-common-ref:2.4.0",
  ];
}

/** 内置版本，逐项用 `bas_*_version` 环境变量覆盖。 */
EmbedVersions embedVersions() @trusted {
  EmbedVersions v;
  v.engine = envOr("bas_engine_version", v.engine);
  v.scala = envOr("bas_scala_version", v.scala);
  v.commons = envOr("bas_commons_version", v.commons);
  v.slf4j = envOr("bas_slf4j_version", v.slf4j);
  v.logback = envOr("bas_logback_version", v.logback);
  v.tomcat = envOr("bas_tomcat_version", v.tomcat);
  v.undertow = envOr("bas_undertow_version", v.undertow);
  v.undertowEe = envOr("bas_undertow_ee_version", v.undertowEe);
  return v;
}

/** 环境变量有非空值则取它，否则用内置缺省。 */
private string envOr(string key, string fallback) @trusted {
  auto value = strip(environment.get(key, ""));
  return value.length ? value : fallback;
}

/** `--key=value` 形式：匹配时写入 `target` 并返回 true。 */
private bool assignValue(string arg, string prefix, ref string target) {
  if (!arg.startsWith(prefix))
    return false;
  target = arg[prefix.length .. $];
  return true;
}
