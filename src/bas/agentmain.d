/**
 * `basagent`：远端控制通道与显式配置拉取。
 *
 * 不带子命令时是常驻 agent；`pull` / `report` 是同一可执行程序里的显式动作。
 */
module bas.agentmain;

import bas.agent : runAgent, runReport;
import bas.cli : takeConfigFile;
import bas.pull : runPull;
import bas.versioninfo : basctlVersion;

import std.stdio : stderr, writeln;
import std.string : startsWith;

version (unittest) {
} else {
  int main(string[] args) {
    version (Posix) {
      import core.sys.posix.unistd : geteuid;

      if (geteuid() == 0) {
        stderr.writeln("basagent: refusing to run as root; use the dedicated bas service account.");
        return 2;
      }
    }
    try
      return dispatch(args);
    catch (Exception e) {
      stderr.writeln("basagent: ", e.msg);
      return 1;
    }
  }

  private int dispatch(string[] args) {
    if (args.length < 2) {
      string[] rest;
      return runAgent(takeConfigFile(rest), basctlVersion, rest);
    }
    switch (args[1]) {
    case "pull":
      return runPull(args[2 .. $]);
    case "report": {
      auto rest = args[2 .. $];
      return runReport(takeConfigFile(rest), basctlVersion, rest);
    }
    case "version", "-v", "--version":
      writeln("basagent " ~ basctlVersion);
      return 0;
    case "help", "-h", "--help":
      usage();
      return 0;
    default:
      if (args[1].startsWith("-")) {
        stderr.writeln("Unknown option: " ~ args[1]);
        usage();
        return 1;
      }
      auto rest = args[1 .. $];
      return runAgent(takeConfigFile(rest), basctlVersion, rest);
    }
  }

  private void usage() {
    stderr.writeln("Usage: basagent [server.xml]");
    stderr.writeln("       basagent pull [--file=<basctl.conf>] [--if-configured] [workdir]");
    stderr.writeln("       basagent report [server.xml]");
    stderr.writeln("       basagent version");
    stderr.writeln("  Without a subcommand, stay connected to the hub as the local agent.");
  }
}
