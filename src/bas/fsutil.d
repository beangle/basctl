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

/** 目录 / 软链接工具。 */
module bas.fsutil;

import std.file : FileException, SpanMode, dirEntries, exists, isDir, isSymlink, mkdirRecurse,
  remove, rmdir, symlink;
import std.path : buildPath;
import std.string : toStringz;

/**
 * Whether `path` exists, treating a dangling symlink as existing.
 *
 * `std.file.exists` / `std.file.isSymlink` 对不存在的路径可能抛 `FileException`，
 * 这里统一兜住，得到「路径上没有东西」的语义。
 */
bool pathExists(string path) {
  try {
    if (isSymlink(path))
      return true;
    return exists(path);
  } catch (FileException) {
    return false;
  }
}

/** Whether `path` is a symlink; false when absent instead of throwing. */
bool isLink(string path) {
  try
    return isSymlink(path);
  catch (FileException)
    return false;
}

/**
 * Deletes a file, symlink or directory tree.
 *
 * 与 `rmdirRecurse` 不同：先判断软链，**不会**跟随 `logs` / `lib` 这类指向引擎目录的
 * 软链去删引擎里的文件。软链只删除链接本身。
 */
void removeTree(string path) {
  if (isLink(path)) {
    remove(path);
    return;
  }
  if (!pathExists(path))
    return;
  if (!isDir(path)) {
    remove(path);
    return;
  }
  foreach (entry; dirEntries(path, SpanMode.shallow)) {
    auto child = entry.name;
    if (isLink(child) || !entry.isDir)
      remove(child);
    else
      removeTree(child);
  }
  rmdir(path);
}

/** Creates `linkPath -> target` when the link does not exist yet. */
void linkIfMissing(string target, string linkPath) {
  if (!pathExists(linkPath))
    symlink(target, linkPath);
}

/** Creates `parent/name -> target` when missing. */
void linkInto(string target, string parent, string name) {
  mkdirRecurse(parent);
  linkIfMissing(target, buildPath(parent, name));
}

/** Whether the directory exists and contains no entries. */
bool isEmptyDir(string path) {
  if (!pathExists(path) || !isDir(path))
    return true;
  foreach (_; dirEntries(path, SpanMode.shallow))
    return false;
  return true;
}

/** Marks a file executable（POSIX）, no-op elsewhere. */
void setExecutable(string path) {
  version (Posix) {
    import core.sys.posix.sys.stat : chmod;

    chmod(path.toStringz, 0b111_101_101); // 0755: rwxr-xr-x
  }
}

/**
 * Creates `path` (and its parents) and forces 0700 on `path` itself（POSIX）.
 *
 * `mkdirRecurse` 按调用者 umask 建目录（`umask 002` 会得到 0775），随后 jstart 接管
 * `servers/<name>` 时会先看到"已存在且组内可写"，于是每次都打一行收紧告警——那是 basctl
 * 自己留下的痕迹，不是用户的配置问题。实例目录从创建起就是 0700，这行噪音和 jstart 的
 * 事后 chmod 都省了。父目录（如 `servers/`）保持 umask 语义，免得改变运维对 `BAS_HOME`
 * 的既有预期。
 */
void mkdirPrivate(string path) {
  mkdirRecurse(path);
  version (Posix) {
    import core.sys.posix.sys.stat : chmod;
    import std.conv : octal;

    chmod(path.toStringz, octal!700);
  }
}
