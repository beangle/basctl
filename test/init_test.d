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
import bas.remote : parseRemoteConf;

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
  assert(result.confWritten);
  assert(!result.confKept);
  assert(exists(buildPath(root, "conf")));
  foreach (name; names) {
    auto path = buildPath(root, "bin", name);
    assert(exists(path));
    assert(readText(path).length > 0);
  }
  assert(readText(buildPath(root, "bin", "env.sh")).canFind("basctl_cmd"));
  assert(readText(buildPath(root, "bin", "env.sh")).canFind("basagent_cmd"));
}

@("installScripts keeps existing scripts unless forced") unittest {
  auto root = newRoot("keep");
  scope (exit) if (exists(root)) rmdirRecurse(root);

  installScripts(root, false, false);
  auto bas = buildPath(root, "bin", "bas.sh");
  write(bas, "CUSTOM");

  auto kept = installScripts(root, false, false);
  assert(kept.written == 0 && kept.kept == scriptCount);
  assert(!kept.confWritten && kept.confKept);
  assert(readText(bas) == "CUSTOM");

  auto forced = installScripts(root, true, false);
  assert(forced.written == scriptCount && forced.kept == 0);
  assert(!forced.confWritten && forced.confKept);
  assert(readText(bas).canFind("basctl_cmd"));
}

@("installScripts writes a commented basctl.conf template with empty remote fields") unittest {
  auto root = newRoot("remote-template");
  scope (exit) if (exists(root)) rmdirRecurse(root);

  auto result = installScripts(root, false, false);
  assert(result.confWritten);

  auto conf = buildPath(root, "conf", "basctl.conf");
  auto text = readText(conf);
  assert(text.canFind("# basctl.conf"), text);
  assert(text.canFind("[remote]"), text);
  assert(text.canFind("url ="), text);
  assert(text.canFind("project ="), text);
  assert(text.canFind("token ="), text);

  auto remote = parseRemoteConf(text);
  assert(!remote.complete);
  assert(!remote.url.length && !remote.project.length && !remote.token.length);

  version (Posix) {
    import core.sys.posix.sys.stat : lstat, stat_t;
    import std.conv : octal;
    import std.string : toStringz;

    stat_t st;
    assert(lstat(conf.toStringz, &st) == 0);
    assert((st.st_mode & octal!777) == octal!600);
  }
}

@("installScripts dry run touches nothing") unittest {
  auto root = newRoot("dry");
  scope (exit) if (exists(root)) rmdirRecurse(root);

  auto result = installScripts(root, false, true);
  assert(result.written == scriptCount);
  assert(result.confWritten);
  assert(!exists(root));
}

@("installScripts never rewrites conf/basctl.conf, even with force") unittest {
  auto root = newRoot("remote-conf");
  scope (exit) if (exists(root)) rmdirRecurse(root);

  installScripts(root, false, false);
  auto conf = buildPath(root, "conf", "basctl.conf");
  write(conf, "[remote]\nurl = https://hub.example.com\n");

  installScripts(root, true, false);
  assert(readText(conf) == "[remote]\nurl = https://hub.example.com\n");
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
      ["beangle_basctl": fake]);

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
      ["beangle_basctl": fake]);

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
      ["beangle_basagent": fake]);

  assert(result.status == 0, result.output);
  assert(readText(buildPath(root, "fake-agent-calls")) == "pull " ~ root ~ "\n");
}
