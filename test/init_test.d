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

import bas.fsutil : setExecutable;
import bas.init : installScripts, runInit;

import std.algorithm : canFind;
import std.file : exists, readText, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.process : execute;
import std.uuid : randomUUID;

private immutable string[] names =
  ["env.sh", "bas.sh", "start.sh", "stop.sh", "restart.sh"];

private enum scriptCount = 5;

private string newRoot(string tag) {
  return buildPath(tempDir, "basctl-init-" ~ tag ~ "-" ~ randomUUID().toString());
}

private string fakeBasctl(string root) {
  auto path = buildPath(root, "fake-basctl.sh");
  write(path, "#!/bin/bash\n"
      ~ "printf '%s\\n' \"$*\" >> \"$BAS_HOME/fake-calls\"\n"
      ~ "exit 0\n");
  setExecutable(path);
  return path;
}

private string fakeBasagent(string root) {
  auto path = buildPath(root, "fake-basagent.sh");
  write(path, "#!/bin/bash\n"
      ~ "printf '%s\\n' \"$*\" >> \"$BAS_HOME/fake-agent-calls\"\n"
      ~ "if [ \"$1\" = pull ]; then exit \"${FAKE_AGENT_PULL_STATUS:-0}\"; fi\n"
      ~ "echo 'fake basagent started'\n"
      ~ "trap 'exit 0' TERM\n"
      ~ "while :; do sleep 1; done\n");
  setExecutable(path);
  return path;
}

@("installScripts writes the control scripts") unittest {
  auto root = newRoot("all");
  scope (exit) if (exists(root)) rmdirRecurse(root);

  auto result = installScripts(root, false, false);
  assert(result.written == scriptCount);
  assert(result.kept == 0);
  assert(exists(buildPath(root, "conf")));
  assert(!exists(buildPath(root, "conf", "basctl.env")));
  foreach (name; names) {
    auto path = buildPath(root, "bin", name);
    assert(exists(path));
    assert(readText(path).length > 0);
  }
  auto env = readText(buildPath(root, "bin", "env.sh"));
  assert(env.canFind("basctl_cmd"));
  assert(env.canFind("basagent_cmd"));
  assert(env.canFind("/etc/bas/conf/basctl.env"));
}

@("installScripts keeps existing scripts unless forced") unittest {
  auto root = newRoot("keep");
  scope (exit) if (exists(root)) rmdirRecurse(root);

  installScripts(root, false, false);
  auto bas = buildPath(root, "bin", "bas.sh");
  write(bas, "CUSTOM");

  auto kept = installScripts(root, false, false);
  assert(kept.written == 0 && kept.kept == scriptCount);
  assert(readText(bas) == "CUSTOM");

  auto forced = installScripts(root, true, false);
  assert(forced.written == scriptCount && forced.kept == 0);
  assert(readText(bas).canFind("basctl_cmd"));
}

@("installScripts dry run touches nothing") unittest {
  auto root = newRoot("dry");
  scope (exit) if (exists(root)) rmdirRecurse(root);

  auto result = installScripts(root, false, true);
  assert(result.written == scriptCount);
  assert(!exists(root));
}

@("runInit rejects unknown options") unittest {
  assert(runInit(["--nope"]) == 1);
}

@("start.sh starts from the local server.xml without pulling") unittest {
  auto root = newRoot("start-local");
  scope (exit) if (exists(root)) rmdirRecurse(root);

  installScripts(root, false, false);
  auto fake = fakeBasctl(root);
  auto result = execute(["bash", buildPath(root, "bin", "start.sh"), "tools"],
      ["beangle_basctl": fake, "BAS_ENV_FILE": buildPath(root, "no.env")]);

  assert(result.status == 0, result.output);
  auto calls = readText(buildPath(root, "fake-calls"));
  assert(calls.canFind("start " ~ buildPath(root, "conf", "server.xml") ~ " tools"), calls);
  assert(!calls.canFind("pull "), calls);
}

@("restart.sh resolves, stops and starts once without pulling") unittest {
  auto root = newRoot("restart-local");
  scope (exit) if (exists(root)) rmdirRecurse(root);

  installScripts(root, false, false);
  auto fake = fakeBasctl(root);
  auto result = execute(["bash", buildPath(root, "bin", "restart.sh"), "tools"],
      ["beangle_basctl": fake, "BAS_ENV_FILE": buildPath(root, "no.env")]);

  assert(result.status == 0, result.output);
  auto calls = readText(buildPath(root, "fake-calls"));
  assert(calls.canFind("resolve " ~ buildPath(root, "conf", "server.xml") ~ " tools"), calls);
  assert(calls.canFind("stop " ~ buildPath(root, "conf", "server.xml") ~ " tools"), calls);
  assert(calls.canFind("start " ~ buildPath(root, "conf", "server.xml") ~ " tools"), calls);
  assert(!calls.canFind("pull "), calls);
}

@("bas.sh pull delegates to basagent") unittest {
  auto root = newRoot("pull");
  scope (exit) if (exists(root)) rmdirRecurse(root);

  installScripts(root, false, false);
  auto fake = fakeBasagent(root);
  auto result = execute(["bash", buildPath(root, "bin", "bas.sh"), "pull"],
      ["beangle_basagent": fake, "BAS_ENV_FILE": buildPath(root, "no.env")]);

  assert(result.status == 0, result.output);
  assert(readText(buildPath(root, "fake-agent-calls")) == "pull " ~ root ~ "\n");
}
