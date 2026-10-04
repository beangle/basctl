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
 * 容器入口（creator）：把 jstart 的 `[engine] init` 协议翻译成最终启动命令。
 *
 * war 没有 `Main-Class`，jstart 把它交给 spec 声明的 init 脚本：脚本准备容器环境、
 * 把最终 argv（NUL 分隔）写进 `--entry-out` 后退出，jstart 再 exec 那条命令。
 *
 * 单个 webapp 时 jstart 按如下协议运行：
 * `[engine] init <type> --base=<dir> --entry=<war|dir> --engine-classpath-file=<file>
 * --app-classpath-file=<file> --local-repo=<dir> --entry-out=<file>
 * [--app-jvm-arg=<opt>]... [args...]`
 *
 * jstart 的 `[engine] init` 可直接写成本命令（jstart 支持“程序 + 参数”），无需 wrapper：
 * `init = basctl make tomcat-embed`
 *
 * 多 webapp（jstart 的 `[subapp <id>]`）不再传 `--entry`，改为把每个 webapp 的
 * entry/path/libs 写进 `<base>/engine-subapps.jstart`；`tomcat-dist` 逐段准备 docBase 并
 * 在同一 JVM 里建多个 `<Context>`（各 Context 用自己的 `DependencyClassLoader` 解析依赖）。
 *
 * 支持的类型见 {@link runEngineCreator}：嵌入式 tomcat / undertow，以及全量 tomcat
 * 发行包（dist）。docBase 布局与 war 解压归入口负责（jstart 不镜像容器布局）。
 */
module bas.enginecreator;

import bas.fsutil : removeTree;
import bas.render : catalinaProperties;

import std.algorithm : canFind;
import std.array : appender, join, split;
import std.conv : to;
import std.file : SpanMode, copy, dirEntries, exists, getSize, isDir, isFile, mkdirRecurse,
  read, readText, remove, write;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath, dirName, dirSeparator,
  pathSeparator;
import std.process : environment;
import std.stdio : stderr;
import std.string : endsWith, indexOf, lastIndexOf, replace, startsWith, strip, toLower;
import std.zip : ZipArchive;

/** 嵌入式 tomcat 的容器入口 main。 */
enum tomcatEmbedMain = "org.beangle.sas.engine.tomcat.Bootstrap";

/** 嵌入式 undertow 的容器入口 main。 */
enum undertowEmbedMain = "org.beangle.sas.engine.undertow.Bootstrap";

/** 全量 tomcat 发行包的容器入口 main。 */
enum tomcatDistMain = "org.apache.catalina.startup.Bootstrap";

/** jstart `[engine] init` 支持的容器类型（`make` 的 creator 模式）。 */
bool isContainerType(string type) @safe nothrow {
  return type == "tomcat-dist" || type == "tomcat-embed" || type == "undertow-embed";
}

/** 精简规则变更时递增，令旧的解压目录重新解压。 */
private enum slimVersion = "slim1";

/** 最终命令参数总长超过该值时改用 `java @argfile`，避免 `E2BIG`。 */
private enum argFileLimit = 4000;

/** base 下 jstart 交付多应用计划的固定文件名（launch spec 片段）。 */
enum subappsPlanFile = "engine-subapps.jstart";

/** 一条引擎属性 `--Dkey=value`（保留出现顺序，故用数组而不是关联数组）。 */
struct EngineProperty {
  string key;
  string value;
}

/** `[engine] init` 协议解析后的参数。 */
struct EngineOptions {
  string base;
  string entry;
  string path = "";
  string engineClasspathFile;
  string appClasspathFile;
  string entryOut;
  string docBase;
  string dist;
  string port;
  string localRepo;
  string mainClass;
  string[] appJvmArgs;
  EngineProperty[] properties;
  string[] listeners;
  bool jspSupport;
  string[] others;

  /** 读取应用依赖 classpath；未给 `--app-classpath-file=` 时为空串。 */
  string appClasspath() {
    if (appClasspathFile.length == 0)
      return "";
    return readClasspathFile(appClasspathFile);
  }

  /** 读取引擎依赖 classpath（`--engine-classpath-file=`）；未给时为空串。 */
  string engineClasspath() {
    if (engineClasspathFile.length == 0)
      return "";
    return readClasspathFile(engineClasspathFile);
  }

  /** 校验单应用必填项，失败时抛出带用法的异常。 */
  void requireSingle(string usage) {
    if (base.length == 0 || entry.length == 0 || entryOut.length == 0)
      throw new Exception("Usage: " ~ usage);
  }
}

/** 读取 jstart 写出的 classpath 文件（内容是 `pathSeparator` 分隔的绝对路径）。 */
private string readClasspathFile(string path) {
  if (!fileHere(path))
    throw new Exception("Cannot read classpath file " ~ path);
  return strip(readText(path));
}

/** `std.file.isFile` 在路径不存在时会抛异常，这里统一成「存在且是文件」。 */
private bool fileHere(string path) {
  return exists(path) && isFile(path);
}

/** `std.file.isDir` 在路径不存在时会抛异常，这里统一成「存在且是目录」。 */
bool dirHere(string path) {
  return exists(path) && isDir(path);
}

/** 解析入口 main 的命令行（协议见模块注释）。 */
EngineOptions parseEngineArgs(string[] args) {
  EngineOptions o;
  foreach (a; args) {
    if (a.startsWith("--base="))
      o.base = valueOf(a);
    else if (a.startsWith("--entry="))
      o.entry = valueOf(a);
    else if (a.startsWith("--entry-out="))
      o.entryOut = valueOf(a);
    else if (a.startsWith("--engine-classpath-file="))
      o.engineClasspathFile = strip(valueOf(a));
    else if (a.startsWith("--app-classpath-file="))
      o.appClasspathFile = strip(valueOf(a));
    else if (a.startsWith("--local-repo="))
      o.localRepo = strip(valueOf(a));
    else if (a.startsWith("--app-jvm-arg="))
      o.appJvmArgs ~= valueOf(a);
    else if (a.startsWith("--listener="))
      o.listeners ~= strip(valueOf(a));
    else if (a.startsWith("--jsp="))
      o.jspSupport = strip(valueOf(a)).toLower == "true";
    else if (a.startsWith("--docBase="))
      o.docBase = strip(valueOf(a));
    else if (a.startsWith("--dist="))
      o.dist = valueOf(a);
    else if (a.startsWith("--main="))
      o.mainClass = strip(valueOf(a));
    else if (a.startsWith("--path="))
      o.path = valueOf(a);
    else if (a.startsWith("--port="))
      o.port = strip(valueOf(a));
    else if (a.startsWith("--D")) {
      // 引擎属性，形如 --Dconnector.maxConnections=20000；无值(--Dxxx)时视为 true
      auto idx = a.indexOf('=');
      if (idx > 3)
        o.properties ~= EngineProperty(strip(a[3 .. idx]), strip(a[idx + 1 .. $]));
      else if (idx < 0 && a.length > 3)
        o.properties ~= EngineProperty(strip(a[3 .. $]), "true");
      else
        stderr.writeln("Malformed engine property [" ~ a ~ "] ignored");
    } else
      o.others ~= a;
  }
  return o;
}

/** `--name=value` 的取值部分。 */
private string valueOf(string arg) {
  return arg[arg.indexOf('=') + 1 .. $];
}

/** 与 `Server.Config.normalizePath` 一致的上下文路径归一化。 */
string normalizePath(string p) {
  if (p.length == 0 || p == "/")
    return "";
  auto path = p;
  if (!path.startsWith("/"))
    path = "/" ~ path;
  while (path.endsWith("/"))
    path = path[0 .. $ - 1];
  while (path.indexOf("//") >= 0)
    path = path.replace("//", "/");
  return path;
}

/** webapp 在 `<base>/webapps` 下的目录名（与 `Server.Config.DocBase` 公式一致）。 */
string docBaseName(string contextPath) {
  auto ctx = normalizePath(contextPath);
  if (ctx.length == 0)
    return "ROOT";
  return ctx[1 .. $].replace("/", "#");
}

/** 从 base+path 推导默认 docBase：`<base>/webapps/<ROOT|a#b>`。 */
string defaultDocBase(string base, string path) {
  return absolutePath(buildPath(buildPath(base, "webapps"), docBaseName(path)));
}

/**
 * jstart 交付的一个 `[subapp <id>]`：入口（war 或已解压目录）、上下文路径与扩展依赖。
 *
 * `libs` 是原始 gav 串（逗号分隔），原样写进该 `<Context>` 的
 * `ExtendableWebappLoader.libs`，由容器内 `DependencyClassLoader` 合并到 war 清单之上。
 */
struct Subapp {
  string id;
  string entry;
  string path;
  string libs;
}

/**
 * 解析 `<base>/engine-subapps.jstart`：`[subapp <id>]` 段，键 `entry` / `path` / `libs`。
 *
 * 忽略注释与空行；键值按首个 `=` 切分（值里可含 `=`）。段缺 `entry` 或 `path` 时抛异常
 * （jstart 写出的文件必然完整，这里是防御）。
 */
Subapp[] parseSubappsPlan(string text) {
  Subapp[] apps;
  Subapp current;
  bool inSection;

  void flush() {
    if (!inSection)
      return;
    if (current.entry.length == 0 || current.path.length == 0)
      throw new Exception("Subapp [" ~ current.id ~ "] needs both entry and path");
    apps ~= current;
  }

  foreach (raw; text.split("\n")) {
    auto line = strip(raw);
    if (line.length == 0 || line.startsWith("#") || line.startsWith(";"))
      continue;
    if (line.startsWith("[")) {
      auto close = line.indexOf(']');
      if (close < 0)
        throw new Exception("Malformed subapp section: " ~ line);
      auto header = strip(line[1 .. close]);
      flush();
      current = Subapp.init;
      inSection = header.startsWith("subapp");
      if (inSection) {
        current.id = strip(header["subapp".length .. $]);
        if (current.id.length == 0)
          throw new Exception("Subapp section needs an id: " ~ line);
      }
      continue;
    }
    if (!inSection)
      continue;
    auto eq = line.indexOf('=');
    if (eq <= 0)
      continue;
    auto key = strip(line[0 .. eq]);
    auto value = strip(line[eq + 1 .. $]);
    if (key == "entry")
      current.entry = value;
    else if (key == "path")
      current.path = value;
    else if (key == "libs")
      current.libs = value;
  }
  flush();
  return apps;
}

/**
 * 校验 subapp 的 id、归一化后的 context path 与 docBase 目录名各自唯一，返回归一化后的
 * context path。docBase 也要查重：`/a/b` 与 `/a#b` 归一化后不同，却会落到同一个
 * `webapps/a#b` 目录，若不拦下先解压的 webapp 会被后一个覆盖。
 */
string[] validateSubapps(Subapp[] apps) {
  string[] ids;
  string[] paths;
  string[] docBases;
  foreach (app; apps) {
    if (ids.canFind(app.id))
      throw new Exception("Duplicate subapp id [" ~ app.id ~ "]");
    ids ~= app.id;
    auto ctx = normalizePath(app.path);
    if (paths.canFind(ctx))
      throw new Exception("Duplicate subapp context path [" ~ (ctx.length ? ctx : "/") ~ "]");
    paths ~= ctx;
    auto bind = docBaseName(ctx);
    if (docBases.canFind(bind))
      throw new Exception("Duplicate subapp docBase [" ~ bind ~ "]");
    docBases ~= bind;
  }
  return paths;
}

/** 读取并校验 `<base>/engine-subapps.jstart`。 */
Subapp[] readSubappsPlan(string base) {
  auto planPath = buildPath(base, subappsPlanFile);
  if (!fileHere(planPath))
    throw new Exception("Missing multi-webapp plan " ~ planPath);
  auto apps = parseSubappsPlan(readText(planPath));
  if (apps.length == 0)
    throw new Exception("Empty multi-webapp plan " ~ planPath);
  validateSubapps(apps);
  return apps;
}

/** server.xml 里一个 `<Context>`：归一化后的上下文路径、docBase 与可选扩展依赖。 */
struct ContextSpec {
  string path;
  string docBase;
  string libs;
}

/**
 * 准备 webapp：entry 是目录则直接作为 docBase（不复制、不解压）；entry 是 war 文件则
 * 清空并解压到 docBase。两种情况下都补齐空的 `WEB-INF/classes`（容器 classloader 会
 * 探测 classpath 上的目录资源）。返回最终 docBase 的绝对路径。
 */
string prepareWebapp(EngineOptions o) {
  return prepareWebappEntry(o.base, o.entry, o.path, o.docBase);
}

/** {@link prepareWebapp} 的显式参数版本，供多应用逐个 subapp 复用（docBase 必须为空，各自按 base+path 推导）。 */
private string prepareWebappEntry(string base, string entry, string path, string docBaseOverride) {
  auto entryFile = entry;
  string docBase;
  if (dirHere(entryFile)) {
    docBase = absolutePath(entryFile);
  } else if (fileHere(entryFile)) {
    docBase = docBaseOverride.length ? absolutePath(docBaseOverride) : defaultDocBase(base, path);
    removeTree(docBase);
    explodeZip(entryFile, docBase);
  } else {
    throw new Exception("Cannot find webapp entry " ~ entry);
  }
  auto classes = buildPath(docBase, "WEB-INF", "classes");
  if (!exists(classes))
    mkdirRecurse(classes);
  return docBase;
}

/** 逐个准备 subapp 的 docBase，得到一个可渲染进 server.xml 的 Context 列表。 */
private ContextSpec[] prepareSubappContexts(EngineOptions o, Subapp[] apps) {
  auto paths = validateSubapps(apps);
  ContextSpec[] contexts;
  foreach (i, app; apps)
    contexts ~= ContextSpec(paths[i], prepareWebappEntry(o.base, app.entry, app.path, ""), app.libs);
  return contexts;
}

/**
 * 最终启动命令的 classpath：引擎 jar + 应用依赖 + `docBase/WEB-INF/classes`
 * 加上 `docBase/WEB-INF/lib/*.jar`（排序）。
 */
string runtimeClasspath(string engineClasspath, string appClasspath, string docBase) {
  string[] paths;
  if (engineClasspath.length)
    paths ~= engineClasspath;
  if (appClasspath.length)
    paths ~= appClasspath;
  auto classes = buildPath(docBase, "WEB-INF", "classes");
  if (exists(classes))
    paths ~= absolutePath(classes);
  auto lib = buildPath(docBase, "WEB-INF", "lib");
  if (dirHere(lib)) {
    import std.algorithm : sort;

    string[] jars;
    foreach (entry; dirEntries(lib, SpanMode.shallow)) {
      if (entry.isFile && baseName(entry.name).endsWith(".jar"))
        jars ~= absolutePath(entry.name);
    }
    jars.sort();
    paths ~= jars;
  }
  return paths.join(pathSeparator);
}

/** java 可执行文件：优先 `JAVA_HOME/bin/java`，兜底 PATH 上的 `java`。 */
string javaExecutable() {
  auto home = strip(environment.get("JAVA_HOME", ""));
  if (home.length) {
    version (Windows)
      enum exe = "java.exe";
    else
      enum exe = "java";
    auto bin = buildPath(home, "bin", exe);
    if (fileHere(bin))
      return absolutePath(bin);
  }
  return "java";
}

/** 把 `--D` 属性还原为容器可识别的参数（EmbedCreator 转发给 CmdOptions）。 */
string[] propertyArgs(EngineProperty[] properties) {
  string[] args;
  foreach (p; properties)
    args ~= "--D" ~ p.key ~ "=" ~ p.value;
  return args;
}

/** 把最终 argv 以 NUL 分隔写入文件（jstart 读到后 exec）。 */
void writeArgv(string path, string[] argv) {
  auto parent = dirName(path);
  if (parent.length)
    mkdirRecurse(parent);
  string buffer;
  foreach (a; argv)
    buffer ~= a ~ "\0";
  write(path, buffer);
}

/**
 * 写出最终启动命令：argv[0] 是 java 可执行文件。命令不长时直接写 argv；超过
 * {@link argFileLimit} 时把 argv[1..] 写入 `<entryOut>.args`（java 参数文件，每行一个
 * 参数），entry-out 只留 `[java, "@<file>"]`，由 java launcher 展开，避免超长 classpath
 * 触发 E2BIG。
 */
void writeLaunchArgv(string entryOut, string[] argv) {
  if (argv.length == 0)
    throw new Exception("Empty launch command");
  int size;
  foreach (i; 1 .. argv.length)
    size += cast(int) argv[i].length + 1;
  if (size <= argFileLimit) {
    writeArgv(entryOut, argv);
    return;
  }
  auto argFile = entryOut ~ ".args";
  auto parent = dirName(argFile);
  if (parent.length)
    mkdirRecurse(parent);
  auto sb = appender!string;
  foreach (i; 1 .. argv.length)
    sb.put(quoteArg(argv[i]) ~ "\n");
  write(argFile, sb.data);
  writeArgv(entryOut, [argv[0], "@" ~ absolutePath(argFile)]);
}

/** java @argfile 中一个参数占一行；含空白/引号/反斜杠或行首为 `#` 时加双引号并转义。 */
string quoteArg(string arg) {
  bool need = arg.length == 0;
  foreach (i, c; arg) {
    if (need)
      break;
    need = c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '"'
      || c == '\'' || c == '\\' || (i == 0 && c == '#');
  }
  if (!need)
    return arg;
  auto sb = appender!string;
  sb.put('"');
  foreach (c; arg) {
    if (c == '\\' || c == '"')
      sb.put('\\');
    sb.put(c);
  }
  sb.put('"');
  return sb.data;
}

/**
 * 解压 zip 到 dest（zip-slip 防护：条目解析出的规范化路径必须仍在 dest 之内）。
 * 目录条目建目录，其余按流复制。
 */
void explodeZip(string zipPath, string dest) {
  mkdirRecurse(dest);
  auto destPath = buildNormalizedPath(dest);
  auto zip = new ZipArchive(cast(ubyte[]) read(zipPath));
  foreach (name, member; zip.directory) {
    auto target = buildNormalizedPath(destPath, name);
    if (target != destPath && !target.startsWith(destPath ~ dirSeparator)) {
      stderr.writeln("Skip unsafe zip entry " ~ name);
      continue;
    }
    if (name.endsWith("/")) {
      mkdirRecurse(target);
      continue;
    }
    auto parent = dirName(target);
    if (parent.length)
      mkdirRecurse(parent);
    write(target, zip.expand(member));
  }
}

/**
 * 嵌入式容器入口：准备 webapp 后写出
 * `java <jvm-args> -cp <引擎 + 应用 + WEB-INF> <Bootstrap> --base= --docBase= ...`。
 */
void createEmbed(string mainClass, EngineOptions o) {
  o.requireSingle("basctl make <tomcat-embed|undertow-embed> --base=<dir> --entry=<war|dir> "
    ~ "--engine-classpath-file=<file> --entry-out=<file> [--app-classpath-file=<file>] "
    ~ "[--app-jvm-arg=<opt>...] [args...]");
  auto docBase = prepareWebapp(o);
  auto base = absolutePath(o.base);

  string[] argv = [javaExecutable()];
  argv ~= o.appJvmArgs;
  // 组件 base 即 bas.home：DependencyClassLoader 由它推 ${bas.home}/webapps 里的快照覆盖
  argv ~= "-Dbas.home=" ~ base;
  if (o.localRepo.length)
    argv ~= "-Dbas.repo=" ~ o.localRepo;
  argv ~= "-cp";
  argv ~= runtimeClasspath(o.engineClasspath(), o.appClasspath(), docBase);
  argv ~= mainClass;
  argv ~= "--base=" ~ base;
  argv ~= "--docBase=" ~ docBase;
  if (o.path.length)
    argv ~= "--path=" ~ o.path;
  if (o.port.length)
    argv ~= "--port=" ~ o.port;
  argv ~= propertyArgs(o.properties);
  argv ~= o.others;

  writeLaunchArgv(o.entryOut, argv);
  stderr.writeln("Engine entry ready: " ~ docBase ~ " -> " ~ o.entryOut);
}

/**
 * 全量 tomcat 发行包入口：解压并精简发行包到 `<base>/engines`，把引擎 jar 复制进
 * `lib/`，生成 `conf/{catalina.properties,web.xml,server.xml}`，写出标准 catalina
 * 启动命令 `java ... -cp <bin/bootstrap.jar> org.apache.catalina.startup.Bootstrap start`。
 */
void createDist(EngineOptions o) {
  o.requireSingle("basctl make tomcat-dist --base=<dir> --entry=<war|dir> --entry-out=<file> "
    ~ "[--dist=<tomcat.zip>] [--engine-classpath-file=<file>] [--app-classpath-file=<file>] "
    ~ "[--app-jvm-arg=<opt>...] [--port=<n>] [--path=<ctx>] [--jsp=true|false] "
    ~ "[--listener=<class[:k=v;...]>]...");

  auto engineClasspath = o.engineClasspath();
  auto appClasspath = o.appClasspath();
  auto docBase = prepareWebapp(o);
  auto zip = resolveDist(o, engineClasspath);
  auto home = prepareDist(o.base, zip, o.jspSupport, engineClasspath);
  auto juliJar = juliFromClasspath(engineClasspath);
  installEngineJars(home, engineClasspath, juliJar);
  writeConf(home, o, [ContextSpec(normalizePath(o.path), docBase, "")]);

  string[] argv = [javaExecutable()];
  argv ~= o.appJvmArgs;
  // bas.home 指向组件 base：DependencyClassLoader 由它推 ${bas.home}/webapps 里的快照覆盖
  argv ~= "-Dbas.home=" ~ absolutePath(o.base);
  if (o.localRepo.length)
    argv ~= "-Dbas.repo=" ~ o.localRepo;
  foreach (p; o.properties)
    argv ~= "-D" ~ p.key ~ "=" ~ p.value;
  argv ~= "-Dcatalina.base=" ~ absolutePath(home);
  argv ~= "-Dcatalina.home=" ~ absolutePath(home);
  argv ~= "-cp";
  argv ~= bootstrapClasspath(home, appClasspath, juliJar);
  argv ~= tomcatDistMain;
  argv ~= "start";

  writeLaunchArgv(o.entryOut, argv);
  stderr.writeln("Engine entry ready: " ~ docBase ~ " -> " ~ o.entryOut);
}

/**
 * 多应用（`[subapp <id>]`）：一个 dist 引擎在同一 JVM 里跑多个 webapp。
 *
 * jstart 不传 `--entry`/`--path`/`--app-classpath-file`，而是把每个 webapp 的
 * entry/path/libs 写进 `<base>/engine-subapps.jstart`。本入口逐个准备 docBase，生成带多个
 * `<Context>` 的 server.xml；每个 Context 由自己的 `DependencyClassLoader` 按该 war 的
 * 清单（叠加 subapp 的 libs）解析依赖——因此应用依赖**不**进 JVM classpath。
 */
void createDistMulti(EngineOptions o) {
  auto apps = readSubappsPlan(o.base);
  auto engineClasspath = o.engineClasspath();
  auto zip = resolveDist(o, engineClasspath);
  auto home = prepareDist(o.base, zip, o.jspSupport, engineClasspath);
  auto juliJar = juliFromClasspath(engineClasspath);
  installEngineJars(home, engineClasspath, juliJar);
  auto contexts = prepareSubappContexts(o, apps);
  writeConf(home, o, contexts);

  string[] argv = [javaExecutable()];
  argv ~= o.appJvmArgs;
  // bas.home 指向组件 base：DependencyClassLoader 由它推 ${bas.home}/webapps 里的快照覆盖
  argv ~= "-Dbas.home=" ~ absolutePath(o.base);
  if (o.localRepo.length)
    argv ~= "-Dbas.repo=" ~ o.localRepo;
  foreach (p; o.properties)
    argv ~= "-D" ~ p.key ~ "=" ~ p.value;
  argv ~= "-Dcatalina.base=" ~ absolutePath(home);
  argv ~= "-Dcatalina.home=" ~ absolutePath(home);
  argv ~= "-cp";
  argv ~= bootstrapClasspath(home, "", juliJar);
  argv ~= tomcatDistMain;
  argv ~= "start";

  writeLaunchArgv(o.entryOut, argv);
  stderr.writeln("Engine entry ready: " ~ apps.length.to!string ~ " webapps -> " ~ o.entryOut);
}

/** 发行包 zip：`--dist` 优先，否则用引擎 classpath 上第一个存在的 `.zip`。 */
private string resolveDist(EngineOptions o, string engineClasspath) {
  if (o.dist.length)
    return o.dist;
  foreach (p; engineClasspath.split(pathSeparator)) {
    if (p.toLower.endsWith(".zip") && fileHere(p))
      return p;
  }
  throw new Exception("No tomcat distribution: pass --dist=<tomcat.zip> or put the zip on the engine classpath");
}

/**
 * 解压发行包到 `<base>/engines` 并返回 tomcat home。已按同一个 zip 解压过则直接复用
 * （用 `.dist` 记录来源 zip 名 + 精简规则版本）；换包或规则变更时先清空再解压。
 */
private string prepareDist(string base, string zip, bool jspSupport, string engineClasspath) {
  auto enginesDir = buildPath(base, "engines");
  auto marker = buildPath(enginesDir, ".dist");
  auto existing = findTomcatHome(enginesDir);
  auto hasJuli = engineClasspathProvidesJuli(engineClasspath);
  // 精简结果随 zip、精简规则、JSP 开关与 juli 来源而变，任一不同都要重新解压
  auto stamp = baseName(zip) ~ ":" ~ getSize(zip).to!string ~ ":" ~ slimVersion
    ~ ":" ~ (jspSupport ? "jsp" : "nojsp") ~ ":" ~ (hasJuli ? "juli" : "nojuli");
  if (existing.length && fileHere(marker)) {
    auto recorded = strip(readText(marker));
    if (stamp == recorded)
      return existing;
  }
  mkdirRecurse(enginesDir);
  removeTree(enginesDir);
  mkdirRecurse(enginesDir);
  explodeZip(zip, enginesDir);
  auto home = findTomcatHome(enginesDir);
  if (home.length == 0)
    throw new Exception("No tomcat home found in " ~ zip ~ " (expected a dir with bin/bootstrap.jar)");
  slim(home, jspSupport, hasJuli);
  write(marker, stamp);
  return home;
}

/** 在解压后的目录里定位 tomcat home（含 `bin/bootstrap.jar` 的那层）。 */
private string findTomcatHome(string enginesDir) {
  if (!dirHere(enginesDir))
    return "";
  foreach (entry; dirEntries(enginesDir, SpanMode.shallow)) {
    if (entry.isDir && fileHere(buildPath(entry.name, "bin", "bootstrap.jar")))
      return entry.name;
  }
  if (fileHere(buildPath(enginesDir, "bin", "bootstrap.jar")))
    return enginesDir;
  return "";
}

/**
 * 把引擎 classpath 上的 jar 复制进 tomcat `lib/`（缺失才复制），供 common.loader 加载。
 *
 * juli 只放 Catalina 的系统 classpath，**不进 `lib/`**；旧版 juli 自带的
 * `META-INF/beangle/dependencies` 若进了 `lib/` 会被 webapp 的 DependencyClassLoader
 * 当成引擎清单读走，把 juli 自身的依赖误当应用依赖解析。
 */
private void installEngineJars(string engineHome, string engineClasspath, string juliJar = "") {
  auto lib = buildPath(engineHome, "lib");
  mkdirRecurse(lib);
  foreach (p; engineClasspath.split(pathSeparator)) {
    if (!p.toLower.endsWith(".jar") || !fileHere(p))
      continue;
    // juli 是 Catalina 系统 classpath 专用：无 deps 文件时由 juliJar 顶替 tomcat-juli.jar，
    // 有 deps 文件时（<=0.13.16）也不能进 lib/，否则同样会污染 DependencyClassLoader。
    if (baseName(p).startsWith("beangle-sas-juli"))
      continue;
    if (juliJar.length && absolutePath(p) == absolutePath(juliJar))
      continue;
    auto target = buildPath(lib, baseName(p));
    if (!exists(target))
      copy(p, target);
  }
}

/** 引擎 classpath 是否已含 juli 实现（`beangle-sas-juli` 把 commons-logging 重命名到其下）。 */
private bool engineClasspathProvidesJuli(string engineClasspath) {
  return juliFromClasspath(engineClasspath).length > 0;
}

/**
 * 精简发行包（原 `TomcatMaker.doMakeEngine` 的清理清单）：删除示例 webapps、日志/工作
 * 目录、文档、conf 里的默认配置、bin 里的 shell/bat、lib 里的 ant/jdbc/i18n/migration
 * 等无用 jar；不启用 JSP 时连 jasper/ecj 一并删除。引擎 classpath 自带 juli 实现时删掉
 * `bin/tomcat-juli.jar` 改用前者。
 */
private void slim(string home, bool jspSupport, bool hasJuli) {
  foreach (d; ["work", "webapps", "logs", "temp"])
    removeTree(buildPath(home, d));
  deleteNames(home, ["RUNNING.txt", "NOTICE", "LICENSE", "RELEASE-NOTES", "BUILDING.txt",
      "CONTRIBUTING.md", "README.md"]);

  deleteNames(buildPath(home, "conf"), ["server.xml", "tomcat-users.xml", "tomcat-users.xsd",
      "jaspic-providers.xml", "jaspic-providers.xsd", "web.xml", "logging.properties"]);

  auto bin = buildPath(home, "bin");
  deleteNames(bin, ["startup.sh", "shutdown.sh", "configtest.sh", "version.sh", "migrate.sh",
      "digest.sh", "tool-wrapper.sh", "catalina.sh", "setclasspath.sh", "makebase.sh"]);
  if (hasJuli)
    deleteNames(bin, ["tomcat-juli.jar"]);
  removeMatching(bin, name => name.endsWith(".xml") || name.endsWith(".bat")
      || name.endsWith("tar.gz") || name.indexOf("daemon") >= 0);

  auto lib = buildPath(home, "lib");
  deleteNames(lib, ["catalina-ant.jar", "catalina-storeconfig.jar", "tomcat-dbcp.jar",
      "tomcat-jdbc.jar", "catalina-tribes.jar", "catalina-ssi.jar", "tomcat-coyote-ffm.jar"]);
  removeMatching(lib, name => name.startsWith("tomcat-i18n-") || name.startsWith("jakartaee-migration"));
  if (!jspSupport) {
    deleteNames(lib, ["jsp-api.jar", "el-api.jar", "jasper.jar", "jasper-el.jar"]);
    removeMatching(lib, name => name.startsWith("ecj"));
  }
}

/** 删除目录下指定名称的直接子项。 */
private void deleteNames(string dir, string[] names) {
  foreach (name; names) {
    auto path = buildPath(dir, name);
    if (exists(path))
      remove(path);
  }
}

/** 删除目录下名称满足 `predicate` 的直接子项，用于清理发行包自带脚本 / jar。 */
private void removeMatching(string dir, bool delegate(string) predicate) {
  if (!dirHere(dir))
    return;
  foreach (entry; dirEntries(dir, SpanMode.shallow)) {
    if (predicate(baseName(entry.name)))
      remove(entry.name);
  }
}

/** 生成实例的 `conf/catalina.properties`、`conf/web.xml` 与 `conf/server.xml`（一个或多个 Context）。 */
private void writeConf(string engineHome, EngineOptions o, ContextSpec[] contexts) {
  auto conf = buildPath(engineHome, "conf");
  mkdirRecurse(conf);
  write(buildPath(conf, "catalina.properties"), catalinaProperties);
  auto major = tomcatMajor(engineHome);
  write(buildPath(conf, "web.xml"), webXml(o.jspSupport, major));
  auto port = o.port.length ? o.port : freePort().to!string;
  write(buildPath(conf, "server.xml"), serverXml(port, contexts, major, o.listeners));
}

/**
 * server.xml：一个 Connector + 一个 Host + 每个 webapp 一个 Context（docBase 为解压目录）。
 * Context 上挂 `ExtendableWebappLoader`/`DependencyClassLoader` 与全关闭的 JarScanner。
 */
string serverXml(string port, ContextSpec[] contexts, string major, string[] listeners) {
  auto sb = appender!string;
  sb.put("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
  sb.put("<Server port=\"-1\" shutdown=\"SHUTDOWN\">\n");
  // 引擎 jar 会被装进 lib/，该类一定可加载；应用全部启动失败时退出以释放端口
  sb.put("  <Listener className=\"org.beangle.sas.engine.tomcat.WebappFailFastListener\"/>\n");
  if (listeners.length == 0) {
    sb.put("  <Listener className=\"org.apache.catalina.core.JreMemoryLeakPreventionListener\"/>\n");
    sb.put("  <Listener className=\"org.apache.catalina.core.ThreadLocalLeakPreventionListener\"/>\n");
  } else {
    foreach (listener; listeners)
      sb.put(listenerXml(listener));
  }
  sb.put("  <Service name=\"Catalina\">\n");
  sb.put("    <Connector port=\"" ~ port ~ "\" protocol=\"HTTP/1.1\" URIEncoding=\"UTF-8\"");
  if (major.startsWith("11"))
    sb.put(" useVirtualThreads=\"true\"");
  sb.put("/>\n");
  sb.put("    <Engine name=\"Catalina\" defaultHost=\"localhost\">\n");
  // deployOnStartup=false：只启动 server.xml 里这个 <Context>，不部署发行包自带的 webapps
  sb.put("      <Host name=\"localhost\" appBase=\"webapps\" unpackWARs=\"true\""
      ~ " autoDeploy=\"false\" deployOnStartup=\"false\" startStopThreads=\"0\""
      ~ " errorReportValveClass=\"org.beangle.sas.engine.tomcat.SwallowErrorValve\">\n");
  foreach (c; contexts)
    sb.put(contextXml(c));
  sb.put("      </Host>\n");
  sb.put("    </Engine>\n");
  sb.put("  </Service>\n");
  sb.put("</Server>\n");
  return sb.data;
}

/** 一个 `<Context>`：Loader 挂 DependencyClassLoader，`libs` 存在时作为 Loader 属性透传。 */
private string contextXml(ContextSpec c) {
  auto sb = appender!string;
  sb.put("        <Context path=\"" ~ xml(c.path) ~ "\" docBase=\"" ~ xml(c.docBase) ~ "\">\n");
  sb.put("          <JarScanner scanBootstrapClassPath=\"false\" scanAllDirectories=\"false\""
      ~ " scanAllFiles=\"false\" scanClassPath=\"false\" scanManifest=\"false\"/>\n");
  sb.put("          <Loader className=\"org.beangle.sas.engine.tomcat.ExtendableWebappLoader\""
      ~ " loaderClass=\"org.beangle.sas.engine.tomcat.DependencyClassLoader\"");
  if (c.libs.length)
    sb.put(" libs=\"" ~ xml(c.libs) ~ "\"");
  sb.put("/>\n");
  sb.put("        </Context>\n");
  return sb.data;
}

/** `--listener=className[:k=v;k2=v2]` 渲染成 Server 级 `<Listener>`。 */
private string listenerXml(string spec) {
  auto colon = spec.indexOf(':');
  auto className = colon < 0 ? spec : spec[0 .. colon];
  auto sb = appender!string;
  sb.put("  <Listener className=\"" ~ xml(className) ~ "\"");
  if (colon >= 0) {
    foreach (pair; spec[colon + 1 .. $].split(";")) {
      if (strip(pair).length == 0)
        continue;
      auto eq = pair.indexOf('=');
      if (eq <= 0)
        continue;
      sb.put(" " ~ strip(pair[0 .. eq]) ~ "=\"" ~ xml(strip(pair[eq + 1 .. $])) ~ "\"");
    }
  }
  sb.put("/>\n");
  return sb.data;
}

/**
 * 生成 `conf/web.xml`：UTF-8 请求/响应编码、`listings=false`、JSP 开关与 mime 映射。
 * 映射表来自内嵌的 `sas/mime.types`（解析语义对齐 beangle-commons 的 `MediaTypes.build`）。
 */
private string webXml(bool jspSupport, string major) {
  auto sb = appender!string;
  sb.put("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
  if (major.startsWith("11")) {
    sb.put("<web-app xmlns=\"https://jakarta.ee/xml/ns/jakartaee\"\n");
    sb.put("  xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"\n");
    sb.put("  xsi:schemaLocation=\"https://jakarta.ee/xml/ns/jakartaee\n");
    sb.put("                      https://jakarta.ee/xml/ns/jakartaee/web-app_6_1.xsd\"\n");
    sb.put("  version=\"6.1\">\n\n");
  } else if (major.startsWith("10.1")) {
    sb.put("<web-app xmlns=\"https://jakarta.ee/xml/ns/jakartaee\"\n");
    sb.put("  xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"\n");
    sb.put("  xsi:schemaLocation=\"https://jakarta.ee/xml/ns/jakartaee\n");
    sb.put("                      https://jakarta.ee/xml/ns/jakartaee/web-app_6_0.xsd\"\n");
    sb.put("  version=\"6.0\">\n\n");
  } else if (major.startsWith("10")) {
    sb.put("<web-app xmlns=\"https://jakarta.ee/xml/ns/jakartaee\"\n");
    sb.put("  xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"\n");
    sb.put("  xsi:schemaLocation=\"https://jakarta.ee/xml/ns/jakartaee\n");
    sb.put("                      https://jakarta.ee/xml/ns/jakartaee/web-app_5_0.xsd\"\n");
    sb.put("  version=\"5.0\">\n\n");
  } else {
    sb.put("<web-app xmlns=\"http://xmlns.jcp.org/xml/ns/javaee\"\n");
    sb.put("  xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"\n");
    sb.put("  xsi:schemaLocation=\"http://xmlns.jcp.org/xml/ns/javaee\n");
    sb.put("                      http://xmlns.jcp.org/xml/ns/javaee/web-app_4_0.xsd\"\n");
    sb.put("  version=\"4.0\">\n\n");
  }
  sb.put("  <request-character-encoding>UTF-8</request-character-encoding>\n");
  sb.put("  <response-character-encoding>UTF-8</response-character-encoding>\n\n");
  sb.put("  <servlet>\n");
  sb.put("    <servlet-name>default</servlet-name>\n");
  sb.put("    <servlet-class>org.apache.catalina.servlets.DefaultServlet</servlet-class>\n");
  sb.put("    <init-param><param-name>debug</param-name><param-value>0</param-value></init-param>\n");
  sb.put("    <init-param><param-name>listings</param-name><param-value>false</param-value></init-param>\n");
  sb.put("    <load-on-startup>1</load-on-startup>\n");
  sb.put("  </servlet>\n\n");
  if (jspSupport) {
    sb.put("  <servlet>\n");
    sb.put("    <servlet-name>jsp</servlet-name>\n");
    sb.put("    <servlet-class>org.apache.jasper.servlet.JspServlet</servlet-class>\n");
    sb.put("    <init-param><param-name>fork</param-name><param-value>false</param-value></init-param>\n");
    sb.put("    <init-param><param-name>xpoweredBy</param-name><param-value>false</param-value></init-param>\n");
    sb.put("    <load-on-startup>3</load-on-startup>\n");
    sb.put("  </servlet>\n\n");
  }
  sb.put("  <servlet-mapping>\n");
  sb.put("    <servlet-name>default</servlet-name>\n");
  sb.put("    <url-pattern>/</url-pattern>\n");
  sb.put("  </servlet-mapping>\n\n");
  if (jspSupport) {
    sb.put("  <servlet-mapping>\n");
    sb.put("    <servlet-name>jsp</servlet-name>\n");
    sb.put("    <url-pattern>*.jsp</url-pattern>\n");
    sb.put("    <url-pattern>*.jspx</url-pattern>\n");
    sb.put("  </servlet-mapping>\n\n");
  }
  sb.put("  <session-config>\n    <session-timeout>30</session-timeout>\n  </session-config>\n\n");
  foreach (e; mimeTypes()) {
    sb.put("  <mime-mapping>\n");
    sb.put("    <extension>" ~ xml(e.key) ~ "</extension>\n");
    sb.put("    <mime-type>" ~ xml(e.value) ~ "</mime-type>\n");
    sb.put("  </mime-mapping>\n");
  }
  sb.put("\n  <welcome-file-list>\n");
  sb.put("    <welcome-file>index.html</welcome-file>\n");
  sb.put("    <welcome-file>index.htm</welcome-file>\n");
  if (jspSupport)
    sb.put("    <welcome-file>index.jsp</welcome-file>\n");
  sb.put("  </welcome-file-list>\n\n</web-app>\n");
  return sb.data;
}

/**
 * 解析 `sas/mime.types`：全名与每个扩展名都映射到同一个 mime 串（对齐 `MediaTypes.build`）。
 * 同名键以先出现者为准，末尾补一条通配 mime。
 */
private EngineProperty[] mimeTypes() {
  import bas.render : mimeTypesResource;

  EngineProperty[] types;
  foreach (raw; mimeTypesResource.split("\n")) {
    auto line = strip(raw);
    if (line.length == 0 || line.startsWith("#"))
      continue;
    auto mime = strip(between(line, "=", "exts"));
    if (mime.length == 0)
      continue;
    if (hasKey(types, mime))
      throw new Exception("Duplicate mime type " ~ mime);
    types ~= EngineProperty(mime, mimeToString(mime));

    auto exts = strip(after(line, "exts"));
    if (exts.length > 0)
      exts = exts[1 .. $];
    if (exts.length == 0)
      continue;
    foreach (ext; exts.split(",")) {
      auto extension = strip(ext);
      if (extension.length == 0 || hasKey(types, extension))
        continue;
      types ~= EngineProperty(extension, mimeToString(mime));
    }
  }
  types ~= EngineProperty("*/*", mimeToString("*/*"));
  return types;
}

private bool hasKey(EngineProperty[] types, string key) {
  foreach (t; types) {
    if (t.key == key)
      return true;
  }
  return false;
}

/** 对齐 beangle-commons `MediaType.toString`：subType 为 `*` 时退化成 primaryType。 */
private string mimeToString(string token) {
  auto semi = token.indexOf(';');
  auto mime = strip(semi > -1 ? token[0 .. semi] : token);
  auto slash = mime.indexOf('/');
  if (slash < 0)
    return mime;
  auto primary = mime[0 .. slash];
  auto sub = mime[slash + 1 .. $];
  return sub == "*" ? primary : primary ~ "/" ~ sub;
}

private string between(string s, string open, string close) {
  auto a = s.indexOf(open);
  if (a < 0)
    return "";
  auto b = s.indexOf(close, a + open.length);
  return b < 0 ? "" : s[a + open.length .. b];
}

private string after(string s, string token) {
  auto i = s.indexOf(token);
  return i < 0 ? "" : s[i + token.length .. $];
}

private string xml(string s) {
  return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;");
}

/**
 * catalina 启动 classpath：`bin/bootstrap.jar[:juli][:应用依赖]`。
 *
 * Catalina 的 Bootstrap 在静态初始化里就要用 `org.apache.juli.logging.LogFactory`，
 * 因此 juli 实现必须在**系统 classpath**（而不是 common.loader 的 `lib/`）上。引擎
 * classpath 自带 juli（beangle-sas-juli）时用它顶替 `bin/tomcat-juli.jar`，否则保留
 * 发行包自带的 `bin/tomcat-juli.jar`。
 */
private string bootstrapClasspath(string engineHome, string appClasspath, string juliJar = "") {
  string[] paths;
  paths ~= absolutePath(buildPath(engineHome, "bin", "bootstrap.jar"));
  if (juliJar.length)
    paths ~= absolutePath(juliJar);
  else {
    auto juli = buildPath(engineHome, "bin", "tomcat-juli.jar");
    if (fileHere(juli))
      paths ~= absolutePath(juli);
  }
  if (appClasspath.length)
    paths ~= appClasspath;
  return paths.join(pathSeparator);
}

/**
 * 引擎 classpath 上可用的 juli jar；没有则返回空串。
 *
 * 判定条件：含有 `org/apache/juli/logging/Log.class`，且**不带**
 * `META-INF/beangle/dependencies`。后者是随包生成的引擎清单，一旦跟着 juli 上了系统
 * classpath，会被 webapp 的 DependencyClassLoader 当成引擎依赖读走。<= 0.13.16 的
 * beangle-sas-juli 就带这个文件，此时视为不可用、退回发行包自带的 `bin/tomcat-juli.jar`
 * （日志不做桥接，但能正常启动）；0.13.17 起该文件已从打包中剔除。
 */
private string juliFromClasspath(string engineClasspath) {
  foreach (p; engineClasspath.split(pathSeparator)) {
    if (!p.toLower.endsWith(".jar") || !fileHere(p))
      continue;
    try {
      auto zip = new ZipArchive(cast(ubyte[]) read(p));
      if ("org/apache/juli/logging/Log.class" in zip.directory
          && !("META-INF/beangle/dependencies" in zip.directory))
        return p;
    } catch (Exception) {
      // 忽略读不了的 jar
    }
  }
  return "";
}

/** 发行包主版本号：目录名形如 `apache-tomcat-11.0.24` 得到 `"11"`。 */
private string tomcatMajor(string engineHome) {
  auto name = baseName(engineHome);
  auto idx = name.lastIndexOf("tomcat-");
  if (idx < 0)
    return "";
  auto rest = name[idx + "tomcat-".length .. $];
  auto dot = rest.indexOf('.');
  return dot > 0 ? rest[0 .. dot] : rest;
}

/** 从 8080 起探测一个空闲端口（对齐 `CmdOptions` 的端口探测）。 */
private int freePort() {
  import std.socket : AddressFamily, InternetAddress, Socket, SocketType;

  foreach (i; 0 .. 100) {
    auto port = 8080 + i;
    try {
      auto socket = new Socket(AddressFamily.INET, SocketType.STREAM);
      scope (exit) socket.close();
      socket.connect(new InternetAddress("localhost", cast(ushort) port));
    } catch (Exception) {
      return port;
    }
  }
  return 8080;
}

/**
 * `basctl make <tomcat-embed|undertow-embed|tomcat-dist> [协议参数...]`：
 * 容器入口（creator），供 jstart 的 `[engine] init` 委托。
 */
int runEngineCreator(string[] args) {
  if (args.length == 0) {
    stderr.writeln("Usage: basctl make <tomcat-embed|undertow-embed|tomcat-dist> [options]");
    return 1;
  }
  auto type = args[0];
  auto o = parseEngineArgs(args[1 .. $]);
  try {
    switch (type) {
    case "tomcat-embed":
      rejectMultiApp(type, o);
      createEmbed(o.mainClass.length ? o.mainClass : tomcatEmbedMain, o);
      return 0;
    case "undertow-embed":
      rejectMultiApp(type, o);
      createEmbed(o.mainClass.length ? o.mainClass : undertowEmbedMain, o);
      return 0;
    case "tomcat-dist":
      if (isMultiApp(o))
        createDistMulti(o);
      else
        createDist(o);
      return 0;
    default:
      stderr.writeln("Unknown engine type: " ~ type);
      return 1;
    }
  } catch (Exception e) {
    stderr.writeln("Engine creator failed: " ~ e.msg);
    return 1;
  }
}

/**
 * 多应用判定：jstart 多应用不给 `--entry`，改为在 base 下写
 * {@link subappsPlanFile}。单应用运行会删除该文件，因此「无 `--entry` 且计划文件存在」
 * 可作可靠判定。
 */
bool isMultiApp(EngineOptions o) {
  if (o.entry.length || o.base.length == 0)
    return false;
  return fileHere(buildPath(o.base, subappsPlanFile));
}

/** 嵌入式容器入口的容器 main 只接受单个 docBase，多应用交由 tomcat-dist。 */
private void rejectMultiApp(string type, EngineOptions o) {
  if (isMultiApp(o))
    throw new Exception(type ~ " does not support multi-webapp; use tomcat-dist");
}
