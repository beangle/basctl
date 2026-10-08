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

/** Unit tests for bas.fsutil. */
module test.fsutil_test;

import bas.fsutil : isLink, linkIfMissing, mkdirPrivate, pathExists, removeTree;

import std.file : exists, mkdir, mkdirRecurse, readText, tempDir, write;
import std.path : buildPath;
import std.uuid : randomUUID;

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

version (Posix) {
  @("mkdirPrivate tightens a fresh directory to 0700 despite a permissive umask") unittest {
    import core.sys.posix.sys.stat : chmod, lstat, stat_t, umask;
    import std.conv : octal;
    import std.string : toStringz;

    auto root = buildPath(tempDir, "basctl-fs3-" ~ randomUUID().toString());
    auto dir = buildPath(root, "instance");
    auto saved = umask(0b010); // 002: 组内可写，正是触发 jstart 收紧告警的那一种
    scope (exit) {
      umask(saved);
      chmod(root.toStringz, octal!700);
      removeTree(root);
    }

    mkdirPrivate(dir);
    stat_t st;
    assert(lstat(dir.toStringz, &st) == 0);
    assert((st.st_mode & octal!777) == octal!700);
  }
}
