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

import std.file : exists, mkdirRecurse, remove, rename;
import std.path : baseName, dirName;
import std.process : execute;
import std.string : lastIndexOf, strip;
import std.stdio : stderr, writeln;

/**
 * Downloads `url` to `local`.
 *
 * 先下载到同目录的 `.名字.part`，成功后再改名，避免跨设备 rename 与半个文件。
 * 失败时不创建目标目录之外的东西，返回 false。
 */
bool curlDownload(string url, string local) {
  mkdirRecurse(dirName(local));
  auto tmpPath = dirName(local) ~ "/." ~ baseName(local) ~ ".part";
  scope (exit) {
    if (exists(tmpPath))
      remove(tmpPath);
  }

  auto cmd = execute(["curl", "--fail", "--silent", "--show-error", "-L",
      "--connect-timeout", "10", "--max-time", "300",
      "--speed-time", "30", "--speed-limit", "1024",
      "-o", tmpPath, url]);
  if (cmd.status != 0 || !exists(tmpPath)) {
    auto detail = strip(cmd.output);
    if (detail.length)
      stderr.writeln("Download failed " ~ url ~ " -> " ~ local ~ ": " ~ detail);
    else
      stderr.writeln("Download failed " ~ url ~ " -> " ~ local);
    return false;
  }
  rename(tmpPath, local);
  return true;
}

/** 下载到 `dir`，返回文件名；已存在则跳过（Scala `SasTool.download`）。 */
string downloadToDir(string url, string dir) {
  auto fileName = url[url.lastIndexOf('/') + 1 .. $];
  auto dest = dir ~ "/" ~ fileName;
  if (!exists(dest))
    curlDownload(url, dest);
  return fileName;
}
