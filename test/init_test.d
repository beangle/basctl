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

/** Unit tests for bas.init. */
module test.init_test;

import bas.init : installScripts, runInit;

import std.algorithm : canFind;
import std.file : exists, readText, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.uuid : randomUUID;

private immutable string[] names = ["env.sh", "bas.sh", "start.sh", "stop.sh", "restart.sh"];

private string newRoot(string tag) {
  return buildPath(tempDir, "basctl-init-" ~ tag ~ "-" ~ randomUUID().toString());
}

@("installScripts writes the control scripts") unittest {
  auto root = newRoot("all");
  scope (exit) if (exists(root)) rmdirRecurse(root);

  auto result = installScripts(root, false, false);
  assert(result.written == 5);
  assert(result.kept == 0);
  assert(exists(buildPath(root, "conf")));
  foreach (name; names) {
    auto path = buildPath(root, "bin", name);
    assert(exists(path));
    assert(readText(path).length > 0);
  }
  assert(readText(buildPath(root, "bin", "env.sh")).canFind("basctl_cmd"));
}

@("installScripts keeps existing scripts unless forced") unittest {
  auto root = newRoot("keep");
  scope (exit) if (exists(root)) rmdirRecurse(root);

  installScripts(root, false, false);
  auto bas = buildPath(root, "bin", "bas.sh");
  write(bas, "CUSTOM");

  auto kept = installScripts(root, false, false);
  assert(kept.written == 0 && kept.kept == 5);
  assert(readText(bas) == "CUSTOM");

  auto forced = installScripts(root, true, false);
  assert(forced.written == 5 && forced.kept == 0);
  assert(readText(bas).canFind("basctl_cmd"));
}

@("installScripts dry run touches nothing") unittest {
  auto root = newRoot("dry");
  scope (exit) if (exists(root)) rmdirRecurse(root);

  auto result = installScripts(root, false, true);
  assert(result.written == 5);
  assert(!exists(root));
}

@("runInit rejects unknown options") unittest {
  assert(runInit(["--nope"]) == 1);
}
