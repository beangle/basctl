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

module bas.artifact;

import std.algorithm : canFind;
import std.array : split;
import std.string : replace, startsWith, strip;

/** The `gav://` scheme marking a Maven coordinate embedded in a URI. */
enum gavProtocol = "gav://";

/**
 * Maven 坐标（gav），形如 `groupId:artifactId[:packaging][:classifier]:version`。
 *
 * 只做坐标解析：拼装 jstart 命令与推算本地仓库路径，实际的解析下载交给本机
 * jstart 命令（见 `bas.jstart`）。
 */
struct Artifact {
  /** Maven 组织标识，如 `org.beangle.sas`。 */
  string groupId;
  /** 构件标识，如 `beangle-sas-engine`。 */
  string artifactId;
  /** 版本；`version` 是 D 关键字，故加下划线后缀。 */
  string version_;
  /** 可选 classifier；空串表示没有。 */
  string classifier;
  /** 打包类型，缺省 `jar`。 */
  string packaging = "jar";

  /** 是否为开发版（版本号含 `SNAPSHOT`）。 */
  bool isSnapshot() const {
    return version_.canFind("SNAPSHOT");
  }

  /** 返回换用新打包类型的副本，例如 jar 换成 war。 */
  Artifact withPackaging(string newPackaging) const {
    Artifact a = this;
    a.packaging = newPackaging;
    return a;
  }

  /** 不带路径的文件名，如 `demo-1.0.4.jar`。 */
  string fileName() const {
    auto name = artifactId ~ "-" ~ version_;
    if (classifier.length)
      return name ~ "-" ~ classifier ~ "." ~ packaging;
    return name ~ "." ~ packaging;
  }

  /** maven2 布局下的版本目录，如 `/org/beangle/sas/demo/1.0.4`。 */
  string dirPath() const {
    return "/" ~ groupId.replace(".", "/") ~ "/" ~ artifactId ~ "/" ~ version_;
  }

  /** maven2 布局下的构件路径，如 `/org/beangle/sas/demo/1.0.4/demo-1.0.4.jar`。 */
  string layoutPath() const {
    return dirPath() ~ "/" ~ fileName();
  }

  /** jstart 可解析的 gav 字符串；无 classifier 且打包为 jar 时省略打包段。 */
  string asGav() const {
    if (classifier.length)
      return groupId ~ ":" ~ artifactId ~ ":" ~ packaging ~ ":" ~ classifier ~ ":" ~ version_;
    if (packaging == "jar")
      return groupId ~ ":" ~ artifactId ~ ":" ~ version_;
    return groupId ~ ":" ~ artifactId ~ ":" ~ packaging ~ ":" ~ version_;
  }

  string toString() const {
    return asGav();
  }
}

/** maven 常见打包类型；4 段的 gav 里第三段命中其中之一才算打包，否则算 classifier。 */
private immutable string[] packagings =
  ["jar", "war", "pom", "zip", "ear", "rar", "ejb", "ejb3", "tar", "tar.gz", "tgz"];

private bool isPackaging(string value) {
  foreach (p; packagings) {
    if (p == value)
      return true;
  }
  return false;
}

/**
 * 解析 gav 字符串，兼容 beangle-boot 的写法：
 *  - `groupId:artifactId:version`
 *  - `groupId:artifactId:packaging:version`
 *  - `groupId:artifactId:classifier:version`（第三段不是打包类型时）
 *  - `groupId:artifactId:packaging:classifier:version`
 */
Artifact parseArtifact(string gav) {
  auto infos = gav.split(":");
  switch (infos.length) {
  case 3:
    return Artifact(infos[0], infos[1], infos[2]);
  case 4:
    if (isPackaging(infos[2]))
      return Artifact(infos[0], infos[1], infos[3], "", infos[2]);
    return Artifact(infos[0], infos[1], infos[3], infos[2], "jar");
  case 5:
    return Artifact(infos[0], infos[1], infos[4], infos[3], infos[2]);
  default:
    throw new Exception("Cannot recognize artifact format " ~ gav);
  }
}

/** Whether uri is a `gav://` coordinate. */
bool isGav(string uri) {
  return uri.startsWith(gavProtocol);
}

/** Whether uri points at a remote http(s) archive. */
bool isRemote(string uri) {
  return uri.startsWith("http://") || uri.startsWith("https://");
}

/** Converts a `gav://` URI into an Artifact; throws when the scheme is missing. */
Artifact toArtifact(string gav) {
  if (!isGav(gav))
    throw new Exception(gav ~ " is not starts with " ~ gavProtocol);
  return parseArtifact(strip(gav[gavProtocol.length .. $]));
}
