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
 * 解析 webapp 的 docBase 与其依赖。
 *
 * 解析/下载全部交给本机 `jstart`（见 `bas.jstart`）；war 的远端直链走 `curl`。
 */
module bas.resolver;

import bas.artifact;
import bas.config;
import bas.download;
import bas.jstart;

import std.algorithm : canFind, endsWith;
import std.file : exists, isDir, timeLastModified;
import std.path : absolutePath, buildPath;
import std.string : empty, replace, split, strip;
import std.stdio : writeln;
import std.typecons : Nullable;

/**
 * 解析每个 webapp 的 docBase 与依赖，返回未能解析的坐标/路径。
 *
 * 对 gav：转成 war 后交给 jstart fetch（开发版用快照仓库，允许 `BAS_HOME/webapps`
 * 下同名 war 覆盖较旧者）；对 http(s)：下载到 `BAS_HOME/webapps`；其余按本地路径处理，
 * 并展开 `${bas.home}` / `../../../` 前缀。
 */
string[] resolveWebapps(string basHome, Repository releaseRepo, SnapshotRepo snapshotRepo, Webapp[] webapps) {
  string[] missings;

  foreach (app; webapps) {
    bool missingDocBase;

    if (isGav(app.uri)) {
      auto gav = toArtifact(app.uri);
      if (gav.packaging == "jar")
        gav = gav.withPackaging("war");
      auto path = resolveArtifact(releaseRepo, snapshotRepo, gav);
      if (!path.isNull) {
        app.docBase = path.get;
        if (gav.isSnapshot()) {
          auto localWar = buildPath(basHome, "webapps", gav.fileName());
          if (exists(localWar) && timeLastModified(localWar) > timeLastModified(path.get))
            app.docBase = absolutePath(localWar);
        }
      } else {
        missingDocBase = true;
        missings ~= gav.asGav();
      }
    } else if (isRemote(app.uri)) {
      auto fileName = downloadToDir(app.uri, buildPath(basHome, "webapps"));
      app.docBase = buildPath(basHome, "webapps", fileName);
    } else {
      auto docBase = app.uri;
      if (docBase.canFind("${bas.home}"))
        docBase = docBase.replace("${bas.home}", basHome);
      else if (docBase.canFind("../../.."))
        docBase = docBase.replace("../../..", basHome);
      app.docBase = docBase;
    }

    if (!app.libs.isNull) {
      foreach (a; parseGavs(app.libs.get))
        resolveArtifact(releaseRepo, snapshotRepo, a);
    }

    if (!missingDocBase) {
      if (exists(app.docBase)) {
        if (app.resolveSupport && resolvable(app.docBase)) {
          auto resolved = resolve(app.docBase, releaseRepo.local, releaseRepo.remotes, releaseRepo.token);
          if (resolved.isNull) {
            writeln("Cannot launch webapp:" ~ app.docBase);
            missings ~= app.docBase;
          }
        }
      } else {
        missings ~= app.docBase;
        writeln("Missing " ~ app.docBase);
      }
    }
  }
  return missings;
}

/**
 * 确保一个构件在本地存在，返回其本地绝对路径。
 *
 * 正式版用 release 仓库、开发版用快照仓库，两者都交给 jstart fetch；上游不可达时
 * 退回本地快照库已有文件。
 */
Nullable!string resolveArtifact(Repository releaseRepo, SnapshotRepo snapshotRepo, Artifact gav) {
  if (gav.isSnapshot())
    return fetch(gav.asGav(), snapshotRepo);
  return fetch(gav.asGav(), releaseRepo);
}

/** 逗号 / 分号 / 换行分隔的 gav 列表。 */
Artifact[] parseGavs(string gavs) {
  Artifact[] artifacts;
  if (gavs.strip().empty)
    return artifacts;
  auto text = gavs.replace(";", ",").replace("\n", ",").replace("\r", "");
  while (text.canFind(",,"))
    text = text.replace(",,", ",");
  foreach (line; text.strip().split(",")) {
    auto token = strip(line);
    if (token.length)
      artifacts ~= parseArtifact(token);
  }
  return artifacts;
}

bool resolvable(string path) {
  if (path.endsWith(".jar") || path.endsWith(".war"))
    return true;
  return exists(path) && isDir(path);
}
