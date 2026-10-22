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

/** 上游下载：调用宿主 `curl` 命令，先落临时文件再原子重命名。 */
module bas.download;

import bas.fsutil : createPrivateFile, setPrivateFile;

import std.algorithm : canFind;
import std.array : appender;
import std.conv : to;
import std.file : exists, mkdirRecurse, remove, rename, write;
import std.path : baseName, buildPath, dirName;
import std.process : execute;
import std.string : lastIndexOf, strip;
import std.stdio : stderr, writeln;
import std.uuid : randomUUID;

/**
 * Downloads `url` to `local`.
 *
 * 先下载到同目录的 `.名字.part`，成功后再改名，避免跨设备 rename 与半个文件。
 * 失败时不创建目标目录之外的东西，返回 false。
 *
 * `headers` 写进临时 curl 配置文件，避免 Bearer token 出现在 `ps` 的命令行里。
 * `httpsOnly` 同时限制初始请求和重定向的协议；`maxBytes` 用于配置这类小文件。
 */
bool curlDownload(string url, string local, string[] headers = null, bool httpsOnly = false,
    long maxBytes = 0) {
  mkdirRecurse(dirName(local));
  auto tmpPath = dirName(local) ~ "/." ~ baseName(local) ~ ".part";
  scope (exit) {
    if (exists(tmpPath))
      remove(tmpPath);
  }
  // 预创建为 0600：curl 写出期间也不会按 umask 短暂暴露。
  // 若进程被强杀，scope(exit) 不会执行，但残留文件仍是私有的。
  createPrivateFile(tmpPath);

  string[] args = ["curl", "--fail", "--silent", "--show-error", "-L",
      "--max-redirs", "5",
      "--connect-timeout", "10", "--max-time", "300",
      "--speed-time", "30", "--speed-limit", "1024"];
  if (httpsOnly)
    args ~= ["--proto", "=https", "--proto-redir", "=https"];
  if (maxBytes > 0)
    args ~= ["--max-filesize", maxBytes.to!string];

  string headerConfig;
  scope (exit) {
    if (headerConfig.length && exists(headerConfig))
      remove(headerConfig);
  }
  if (headers.length) {
    headerConfig = buildPath(dirName(local), ".curl-headers-" ~ randomUUID().toString);
    string content;
    foreach (header; headers) {
      if (header.canFind('\n') || header.canFind('\r') || header.canFind('\0')) {
        stderr.writeln("Refusing curl header containing a line break");
        return false;
      }
      content ~= "header = " ~ curlQuote(header) ~ "\n";
    }
    createPrivateFile(headerConfig);
    write(headerConfig, content);
    args ~= ["--config", headerConfig];
  }
  args ~= ["-o", tmpPath, url];
  auto cmd = execute(args);
  if (cmd.status != 0 || !exists(tmpPath)) {
    auto detail = strip(cmd.output);
    if (detail.length)
      stderr.writeln("Download failed " ~ url ~ " -> " ~ local ~ ": " ~ detail);
    else
      stderr.writeln("Download failed " ~ url ~ " -> " ~ local);
    return false;
  }
  setPrivateFile(tmpPath);
  rename(tmpPath, local);
  return true;
}

/** curl 配置文件里的双引号字符串；只转义反斜杠和双引号。 */
private string curlQuote(string value) {
  auto result = appender!string;
  result.put('"');
  foreach (ch; value) {
    if (ch == '\\' || ch == '"')
      result.put('\\');
    result.put(ch);
  }
  result.put('"');
  return result.data;
}

/** 下载到 `dir`，返回文件名；已存在则跳过。`headers` 透传给 curl。 */
string downloadToDir(string url, string dir, string[] headers = null) {
  auto fileName = url[url.lastIndexOf('/') + 1 .. $];
  auto dest = dir ~ "/" ~ fileName;
  if (!exists(dest))
    curlDownload(url, dest, headers);
  return fileName;
}
