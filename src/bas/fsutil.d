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

/** 目录 / 软链接工具，替代 Scala 的 `org.beangle.commons.io.Dirs`（用到的部分）。 */
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

version (unittest) {
  import std.file : mkdir, readText, tempDir, write;
  import std.uuid : randomUUID;
}

@("removeTree unlinks symlinks without touching targets") unittest {
  auto root = buildPath(tempDir, "basctl-fs-" ~ randomUUID().toString());
  mkdirRecurse(root);
  scope (exit) removeTree(root);

  mkdir(buildPath(root, "target"));
  write(buildPath(root, "target", "keep.txt"), "keep");
  mkdir(buildPath(root, "base"));
  linkIfMissing(buildPath(root, "target"), buildPath(root, "base", "lib"));

  removeTree(buildPath(root, "base"));
  assert(exists(buildPath(root, "target", "keep.txt")));
  assert(readText(buildPath(root, "target", "keep.txt")) == "keep");
}

@("pathExists handles dangling symlinks") unittest {
  auto root = buildPath(tempDir, "basctl-fs2-" ~ randomUUID().toString());
  mkdirRecurse(root);
  scope (exit) removeTree(root);

  assert(!pathExists(buildPath(root, "none")));
  linkIfMissing(buildPath(root, "none"), buildPath(root, "dangling"));
  assert(isLink(buildPath(root, "dangling")));
  assert(pathExists(buildPath(root, "dangling")));
}
