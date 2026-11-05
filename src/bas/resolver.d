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
import std.string : empty, replace, split, startsWith, strip;
import std.process : environment;
import std.stdio : writeln;
import std.typecons : Nullable, nullable;

/**
 * 解析每个 webapp 的 docBase 与依赖，返回未能解析的坐标/路径。
 *
 * 对 gav：转成 war 后交给 jstart fetch（快照也只用仓库解析结果，不读本地 webapps 覆盖）；
 * 对 http(s)：下载到 `~/.m2/downloads`；其余按本地路径处理，并展开 `${bas.home}` /
 * `../../../` 前缀。
 */
/** 当前用户 home；下载缓存放在 `~/.m2/downloads`，不写回 BAS_HOME。 */
private string mavenHome() {
  auto home = environment.get("HOME", "").strip;
  if (home.length == 0)
    throw new Exception("HOME is not set; cannot locate ~/.m2/downloads");
  return home;
}

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
      } else {
        missingDocBase = true;
        missings ~= gav.asGav();
      }
    } else if (isRemote(app.uri)) {
      auto downloadDir = buildPath(mavenHome(), ".m2", "downloads");
      auto fileName = downloadToDir(app.uri, downloadDir,
          authHeadersFor(app.uri, releaseRepo, snapshotRepo));
      app.docBase = buildPath(downloadDir, fileName);
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
          auto resolved = resolve(app.docBase, releaseRepo);
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
 * 两者都交给 jstart fetch；fetch 对 Maven SNAPSHOT 的 jar/war 会按 `latest` /
 * `maven-metadata.xml` 解析最新时间戳，native tar.gz 才按字面版本处理。
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

/** 仅当 URL 落在已配置仓库根之下时附上该仓库令牌，避免向无关主机泄漏凭据。 */
private string[] authHeadersFor(string url, Repository releaseRepo, SnapshotRepo snapshotRepo) {
  string best;
  string token;
  auto snapshotRemotes = snapshotRepo.remotes;
  auto snapshotTokens = snapshotRepo.tokens;
  foreach (i, base; snapshotRemotes) {
    if (urlMatches(url, base) && base.length > best.length) {
      best = base;
      token = i < snapshotTokens.length ? snapshotTokens[i] : "";
    }
  }
  auto releaseRemotes = releaseRepo.remotes;
  auto releaseTokens = releaseRepo.tokens;
  foreach (i, base; releaseRemotes) {
    if (urlMatches(url, base) && base.length > best.length) {
      best = base;
      token = i < releaseTokens.length ? releaseTokens[i] : "";
    }
  }
  return token.length ? ["Authorization: Bearer " ~ token] : [];
}

private bool urlMatches(string url, string base) {
  return base.length > 0 && (url == base || url.startsWith(base ~ "/"));
}
