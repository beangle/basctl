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
 * 编排入口：把 `server.xml` 变成可运行的实例目录。
 */
module bas.maker;

import bas.config;
import bas.fsutil;
import bas.net;
import bas.resolver;
import bas.serverstatus;
import bas.tomcatmaker;

import std.algorithm : canFind;
import std.array : join;
import std.file : exists, mkdirRecurse, remove, write;
import std.path : absolutePath, buildPath, dirName;
import core.stdc.stdlib : exit;
import std.stdio : stderr, writeln;

/** `make <config> <serverPattern>`：从配置文件推导 SAS_HOME 后生成。 */
int runMaker(string configFile, string serverPattern) {
  if (!exists(configFile)) {
    stderr.writeln("Cannot find config file " ~ configFile);
    return 1;
  }
  auto container = parseServerXmlFile(configFile);
  auto sasHome = dirName(dirName(absolutePath(configFile)));
  make(container, sasHome, serverPattern);
  return 0;
}

/**
 * 选择部署在本机、且匹配 pattern 的 server，先解析应用，再生成引擎与实例。
 *
 * `serverPattern` 可为 `all`、farm 名或 `farm.server`。未解析成功的实例会写入
 * `servers/<name>/error`，成功则清掉该文件。
 */
void make(Container container, string sasHome, string serverPattern) {
  auto releaseRepo = container.repository;
  auto snapshotRepo = container.snapshotRepo;
  auto ips = localAddresses();

  Engine[] engines;
  Server[] servers;
  foreach (farm; container.farms) {
    foreach (server; farm.servers) {
      if (!ips.canFind(server.host.ip))
        continue;
      if (serverPattern == "all" || serverPattern == farm.name || serverPattern == server.qualifiedName) {
        servers ~= server;
        if (!engines.canFind(farm.engine))
          engines ~= farm.engine;
      }
    }
  }

  string[string] missings;
  foreach (server; servers)
    missings[server.qualifiedName] = resolveWebapps(sasHome, releaseRepo, snapshotRepo,
        container.getWebapps(server)).join("\n");

  foreach (engine; engines) {
    if (engine.typ == engineTomcat) {
      applyEngineDefault(container, engine);
      makeEngine(sasHome, engine, releaseRepo);
    } else {
      stderr.writeln("Cannot recognize engine type " ~ engine.typ);
      exit(1);
    }
  }

  foreach (server; servers) {
    auto dir = buildPath(sasHome, "servers", server.qualifiedName);
    auto errorFile = buildPath(dir, "error");
    if (missings[server.qualifiedName].length) {
      mkdirRecurse(dir);
      write(errorFile, missings[server.qualifiedName]);
      writeln("Cannot resolve " ~ server.qualifiedName ~ ",see details: " ~ errorFile);
    } else {
      makeOrCleanServer(sasHome, container, server);
      if (exists(errorFile))
        remove(errorFile);
    }
  }
}

private void makeOrCleanServer(string sasHome, Container container, Server server) {
  auto webapps = container.getWebapps(server);
  if (!webapps.length) {
    auto dir = buildPath(sasHome, "servers", server.qualifiedName);
    if (exists(dir) && detectExecution(server).isNull)
      removeTree(dir);
  } else if (server.farm.engine.typ == engineTomcat) {
    makeServer(sasHome, container, server);
  }
}
