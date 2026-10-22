/* Copyright (C) 2026 Beangle
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
 * `conf/basctl.conf`：basctl 与控制台之间的远程连接配置。
 *
 * 远程地址、Profile 名与凭证都只从这里读取；`pull` 不再依赖 `ip:` 请求头，也不再
 * 从环境变量推断控制台地址。文件格式是简单的 INI：
 *
 *     [remote]
 *     url = https://hub.example.com
 *     profile = openurp.prod
 *     token = <Profile.key>
 *
 * `url` 是控制台根地址（含反向代理前缀），不是某个 Profile 的完整地址；Profile 与
 * 凭证分别由 `profile` / `token` 给出。所有端点按 bashub 的能力域拼接：
 *
 *     <url>/api/bashub/config/<profile>/server
 *     <url>/api/bashub/monitor/agents/<profile>/channel
 */
module bas.remote;

import std.algorithm : startsWith;
import std.file : exists, readText;
import std.path : buildPath, dirName;
import std.string : indexOf, splitLines, strip;

/** 配置文件相对 `BAS_HOME/conf` 的文件名。 */
enum remoteConfFileName = "basctl.conf";

/** bashub API 的固定根路径。 */
private enum bashubApiPath = "/api/bashub";

/** Raised when `basctl.conf` is incomplete or malformed enough to use. */
class RemoteConfigException : Exception {
  this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null) {
    super(msg, file, line, nextInChain);
  }
}

/** `[remote]` 段的三个字段；空字段表示尚未配置。 */
struct RemoteConfig {
  string url;
  string profile;
  string token;

  /** 是否至少填写了一项；用于区分空模板与填了一半的配置。 */
  bool configured() const {
    return url.length > 0 || profile.length > 0 || token.length > 0;
  }

  /** 三项齐全才允许发起远程请求。 */
  bool complete() const {
    return url.length > 0 && profile.length > 0 && token.length > 0;
  }
}

/** `<BAS_HOME>/conf/basctl.conf`。 */
string remoteConfPath(string basHome) {
  return buildPath(basHome, "conf", remoteConfFileName);
}

/** 与 `server.xml` 同目录的 `basctl.conf`。 */
RemoteConfig remoteConfForServerXml(string serverXmlPath) {
  return loadRemoteConf(buildPath(dirName(serverXmlPath), remoteConfFileName));
}

/** 读取配置；文件不存在时返回空配置，由调用方决定是报错还是跳过。 */
RemoteConfig loadRemoteConf(string path) {
  if (!exists(path))
    return RemoteConfig.init;
  return parseRemoteConf(readText(path));
}

/** 解析 INI 文本；只识别 `[remote]` 下的 `url` / `profile` / `token`。 */
RemoteConfig parseRemoteConf(string text) {
  RemoteConfig result;
  string section;
  foreach (raw; text.splitLines()) {
    auto line = strip(raw);
    if (!line.length || line[0] == '#' || line[0] == ';')
      continue;
    if (line[0] == '[') {
      auto close = line.indexOf(']');
      section = close > 0 ? strip(line[1 .. close]) : "";
      continue;
    }
    if (section != "remote")
      continue;
    auto equals = line.indexOf('=');
    if (equals <= 0)
      continue;
    auto key = strip(line[0 .. equals]);
    auto value = unquote(line[equals + 1 .. $]);
    switch (key) {
    case "url":
      result.url = value;
      break;
    case "profile":
      result.profile = value;
      break;
    case "token":
      result.token = value;
      break;
    default:
      break;
    }
  }
  return result;
}

/** 校验三项是否齐全以及基本的 URL / Profile 形态。 */
void validateRemoteConf(const RemoteConfig conf, string path) {
  if (!conf.url.length)
    throw new RemoteConfigException("No remote.url in " ~ path);
  if (!conf.url.startsWith("http://") && !conf.url.startsWith("https://"))
    throw new RemoteConfigException("remote.url must start with http:// or https:// in " ~ path);
  if (!conf.profile.length)
    throw new RemoteConfigException("No remote.profile in " ~ path);
  if (!validProfileName(conf.profile))
    throw new RemoteConfigException("remote.profile must be org.name in " ~ path);
  if (!conf.token.length)
    throw new RemoteConfigException("No remote.token in " ~ path);
}

/** 控制台根地址：去掉首尾空白与尾部斜杠，供 URL 拼接和 `${bas_remote_url}` 展开共用。 */
string remoteBaseUrl(string url) {
  return stripTrailingSlash(strip(url));
}

/** bashub API 根地址：`<remote.url>/api/bashub`。 */
string hubApiRoot(const RemoteConfig conf) {
  return remoteBaseUrl(conf.url) ~ bashubApiPath;
}

/** `basagent pull` 下载 server.xml 的地址。 */
string serverConfigUrl(const RemoteConfig conf) {
  return hubApiRoot(conf) ~ "/config/" ~ conf.profile ~ "/server";
}

/** 节点通道的 HTTP(S) 地址；拨号时再转换成 WebSocket scheme。 */
string agentChannelUrl(const RemoteConfig conf) {
  return hubApiRoot(conf) ~ "/monitor/agents/" ~ conf.profile ~ "/channel";
}

/** `pull` 与通道握手共用的 Bearer 凭证；bashub 会同时校验 Profile 与 key。 */
string bearerCredential(const RemoteConfig conf) {
  return conf.profile ~ ":" ~ conf.token;
}

/** 去掉尾斜杠，但不破坏 `https://` 这类只有 scheme 的写法。 */
private string stripTrailingSlash(string value) {
  auto result = value;
  while (result.length > "https://".length && result[$ - 1] == '/')
    result = result[0 .. $ - 1];
  return result;
}

/** 去掉成对的单/双引号，方便 `token = "..."` 这种写法。 */
private string unquote(string value) {
  auto result = strip(value);
  if (result.length >= 2
      && ((result[0] == '"' && result[$ - 1] == '"')
        || (result[0] == '\'' && result[$ - 1] == '\'')))
    return result[1 .. $ - 1];
  return result;
}

/** Profile 必须是 `org.name`，不能把路径分隔符混进来。 */
private bool validProfileName(string profile) {
  auto dot = profile.indexOf('.');
  if (dot <= 0 || dot >= profile.length - 1)
    return false;
  foreach (ch; profile) {
    if (ch == '/' || ch == '\\' || ch == ' ' || ch == '\t')
      return false;
  }
  return true;
}
