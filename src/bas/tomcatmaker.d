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
 * Tomcat 引擎与实例目录的生成（Scala `org.beangle.sas.maker.TomcatMaker`）。
 */
module bas.tomcatmaker;

import bas.artifact;
import bas.config;
import bas.download;
import bas.fsutil;
import bas.jstart;
import bas.render;
import bas.serverstatus;
import bas.zip;

import std.conv : to;
import std.file : SpanMode, dirEntries, exists, isFile, mkdirRecurse, remove, rename, write;
import std.path : absolutePath, baseName, buildPath;
import std.stdio : writeln;
import std.string : endsWith, replace, strip;
import std.typecons : nullable;

/** 增加 sas 对 tomcat 的默认要求到配置模型（Scala `applyEngineDefault`）. */
void applyEngineDefault(Container container, Engine engine) {
  if (!engine.listeners.length) {
    engine.listeners ~= new Listener("org.apache.catalina.core.JreMemoryLeakPreventionListener");
    engine.listeners ~= new Listener("org.apache.catalina.core.ThreadLocalLeakPreventionListener");
  }

  if (engine.context is null)
    engine.context = new Context();

  auto context = engine.context;
  if (context.loader is null) {
    context.loader = new Loader("org.beangle.sas.engine.tomcat.ExtendableWebappLoader");
    context.loader.properties["loaderClass"] = "org.beangle.sas.engine.tomcat.DependencyClassLoader";
  }
  if (context.jarScanner is null) {
    auto scanner = new JarScanner();
    scanner.properties["scanBootstrapClassPath"] = "false";
    scanner.properties["scanAllDirectories"] = "false";
    scanner.properties["scanAllFiles"] = "false";
    scanner.properties["scanClassPath"] = "false";
    scanner.properties["scanManifest"] = "false";
    context.jarScanner = scanner;
  }
  engine.jars ~= Jar.gav("org.beangle.sas:beangle-sas-engine:" ~ container.version_);
}

/**
 * 创建（或补齐）一个引擎：解压 Tomcat 发行包，并把引擎 jar 链接到 `lib/`.
 *
 * 已存在的引擎目录不会被重复创建，只检查缺失的 jar。
 */
void makeEngine(string sasHome, Engine engine, Repository repo) {
  auto tomcat = engine.path(sasHome);
  if (!exists(tomcat) || isEmptyDir(tomcat)) {
    auto gav = "org.apache.tomcat:tomcat:zip:" ~ engine.version_;
    auto fetched = fetch(gav, repo);
    if (!fetched.isNull)
      doMakeEngine(sasHome, engine, fetched.get);
    else
      writeln("Cannot download " ~ gav);
  }

  auto libDir = buildPath(tomcat, "lib");
  foreach (jar; engine.jars) {
    auto jarName = jar.name();
    auto target = buildPath(libDir, jarName);
    if (exists(target))
      continue;
    if (isRemote(jar.uri)) {
      downloadToDir(jar.uri, libDir);
    } else if (isGav(jar.uri)) {
      auto fetched = fetch(toArtifact(jar.uri).asGav(), repo);
      if (!fetched.isNull)
        linkIfMissing(fetched.get, target);
      else
        writeln("Cannot download " ~ jar.uri);
    } else {
      linkIfMissing(absolutePath(jar.uri), target);
    }
  }
}

/** 解压 Tomcat zip 到 `SAS_HOME/engines/<name>-<version>`，并清理发行包内容。 */
void doMakeEngine(string sasHome, Engine engine, string tomcatZip) {
  auto engineHome = buildPath(sasHome, "engines");
  mkdirRecurse(engineHome);

  unzipInto(tomcatZip, engineHome);
  auto engineDir = engine.path(sasHome);
  auto extracted = buildPath(engineHome, "apache-tomcat-" ~ engine.version_);
  if (!exists(extracted))
    extracted = findExtractedTomcat(engineHome);
  if (exists(engineDir))
    removeTree(engineDir);
  rename(extracted, engineDir);

  foreach (d; ["work", "webapps", "logs", "temp"])
    removeTree(buildPath(engineDir, d));
  foreach (f; ["RUNNING.txt", "NOTICE", "LICENSE", "RELEASE-NOTES", "BUILDING.txt", "CONTRIBUTING.md", "README.md"])
    removeIfExists(buildPath(engineDir, f));

  auto conf = buildPath(engineDir, "conf");
  foreach (f; ["server.xml", "tomcat-users.xml", "tomcat-users.xsd", "jaspic-providers.xml",
      "jaspic-providers.xsd", "web.xml", "logging.properties"])
    removeIfExists(buildPath(conf, f));
  write(buildPath(conf, "catalina.properties"), catalinaProperties);

  auto bin = buildPath(engineDir, "bin");
  foreach (f; ["startup.sh", "shutdown.sh", "configtest.sh", "version.sh", "migrate.sh",
      "digest.sh", "tool-wrapper.sh", "catalina.sh", "setclasspath.sh", "makebase.sh",
      "ciphers.sh", "tomcat-juli.jar"])
    removeIfExists(buildPath(bin, f));
  removeMatching(bin, name => name.endsWith(".xml") || name.endsWith(".bat")
      || name.endsWith("tar.gz") || name.canFind("daemon"));

  auto lib = buildPath(engineDir, "lib");
  foreach (f; ["catalina-ant.jar", "catalina-storeconfig.jar", "tomcat-dbcp.jar", "tomcat-jdbc.jar",
      "catalina-tribes.jar", "catalina-ssi.jar", "tomcat-coyote-ffm.jar"])
    removeIfExists(buildPath(lib, f));
  removeMatching(lib, name => name.startsWith("tomcat-i18n-") || name.startsWith("jakartaee-migration"));

  if (!engine.jspSupport) {
    foreach (f; ["jsp-api.jar", "el-api.jar", "jasper.jar", "jasper-el.jar"])
      removeIfExists(buildPath(lib, f));
    removeMatching(lib, name => name.startsWith("ecj"));
  }

  write(buildPath(conf, "web.xml"), renderWebXml(engine));
}

/** 在引擎根目录下找出 `apache-tomcat-*` 解压目录（发行包内层目录名）。 */
private string findExtractedTomcat(string engineHome) {
  foreach (entry; dirEntries(engineHome, SpanMode.shallow)) {
    if (entry.isDir && baseName(entry.name).startsWith("apache-tomcat-"))
      return entry.name;
  }
  throw new Exception("Cannot find extracted apache-tomcat directory under " ~ engineHome);
}

/**
 * 创建一个运行实例：若已在运行则只写 `SERVER_PID`，否则生成 base 目录与配置。
 */
void makeServer(string sasHome, Container container, Server server) {
  auto status = detectExecution(server);
  if (!status.isNull) {
    auto dir = buildPath(sasHome, "servers", server.qualifiedName);
    mkdirRecurse(dir);
    write(buildPath(dir, "SERVER_PID"), processIdText(status.get.processId));
  } else {
    doMakeBase(sasHome, container, server);
    rollLog(sasHome, server);
  }
}

/** 生成一个 base 的目录结构和配置文件（Scala `doMakeBase`）. */
void doMakeBase(string sasHome, Container container, Server server) {
  auto engine = server.farm.engine;
  auto base = buildPath(sasHome, "servers", server.qualifiedName);
  mkdirRecurse(base);
  foreach (d; ["temp", "work", "conf"])
    mkdirRecurse(buildPath(base, d));

  foreach (d; ["webapps", "conf", "bin", "logs", "lib"])
    removeTree(buildPath(base, d));
  foreach (d; ["webapps", "conf", "bin"])
    mkdirRecurse(buildPath(base, d));

  auto engineHome = engine.path(sasHome);
  if (exists(engineHome)) {
    linkIfMissing(buildPath(engineHome, "lib"), buildPath(base, "lib"));
    foreach (entry; dirEntries(buildPath(engineHome, "conf"), SpanMode.shallow))
      linkInto(entry.name, buildPath(base, "conf"), baseName(entry.name));
    foreach (entry; dirEntries(buildPath(engineHome, "bin"), SpanMode.shallow))
      linkInto(entry.name, buildPath(base, "bin"), baseName(entry.name));
  }

  auto logsDir = buildPath(sasHome, "logs", server.qualifiedName);
  mkdirRecurse(logsDir);
  linkIfMissing(logsDir, buildPath(base, "logs"));

  foreach (webapp; container.getWebapps(server)) {
    if (exists(webapp.docBase) && isFile(webapp.docBase)) {
      if (webapp.unpack.isNull)
        webapp.unpack = nullable(warHasLibs(webapp.docBase));
      if (webapp.unpack.get)
        unzipWar(base, webapp);
    }
  }

  genBaseConfig(container, server, sasHome);
}

/** 解压 war 到 `webapps/<contextPath with #>` 并更新 docBase（Scala `unzipWar`）. */
void unzipWar(string base, Webapp webapp) {
  auto path = webapp.contextPath;
  if (path.startsWith("/"))
    path = path[1 .. $];
  if (path.endsWith("/"))
    path = path[0 .. $ - 1];
  path = path.replace("/", "#");
  if (strip(path).length == 0)
    path = "ROOT";
  auto docBase = buildPath(base, "webapps", path);
  mkdirRecurse(docBase);
  unzipInto(webapp.docBase, docBase);
  webapp.docBase = absolutePath(docBase);
}

/** 生成实例的 `conf/server.xml` 与 `bin/setenv.sh`（Scala `genBaseConfig`）. */
void genBaseConfig(Container container, Server server, string targetDir) {
  auto serverDir = buildPath(targetDir, "servers", server.qualifiedName);
  mkdirRecurse(serverDir);
  write(buildPath(serverDir, "conf", "server.xml"), renderServerXml(container, server.farm, server));

  auto binDir = buildPath(serverDir, "bin");
  mkdirRecurse(binDir);
  auto setenv = buildPath(binDir, "setenv.sh");
  write(setenv, renderSetenvSh(server.farm, server));
  setExecutable(setenv);
}

/** 存在则删除（文件或软链），不存在时静默跳过。 */
private void removeIfExists(string path) {
  if (pathExists(path))
    remove(path);
}

/** 删除目录下名称满足 `predicate` 的直接子项，用于清理发行包自带脚本 / jar。 */
private void removeMatching(string dir, bool delegate(string) predicate) {
  if (!exists(dir))
    return;
  foreach (entry; dirEntries(dir, SpanMode.shallow)) {
    auto name = baseName(entry.name);
    if (predicate(name))
      remove(entry.name);
  }
}

private import std.algorithm : canFind, startsWith;

/** 把探测到的 pid 写成 `SERVER_PID` 文件内容。 */
private string processIdText(int pid) {
  return pid.to!string;
}
