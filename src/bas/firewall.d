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

/**
 * firewalld 端口配置助手（Scala `org.beangle.sas.tool.Firewall`）。
 */
module bas.firewall;

import bas.config;
import bas.render;
import bas.shellenv;

import std.array : join;
import std.conv : to;
import std.path : absolutePath;
import std.process : Config, execute, environment;
import std.stdio : readln, stdin, writeln;
import std.string : strip;

/** `firewall [workdir]`：读取配置后进入交互式命令循环。 */
int runFirewall(string[] args) {
  auto workdir = args.length > 1 ? absolutePath(args[1]) : absolutePath(environment.get("PWD", "."));
  auto container = readContainer(workdir);
  if (container.isNull) {
    writeln("Missing config file conf/server.xml under " ~ workdir);
    return 1;
  }
  auto cfg = container.get;
  printInfo(cfg);
  while (true) {
    import std.stdio : write, stdout;

    write("firewall> ");
    stdout.flush();
    auto line = strip(readln());
    if (line.length == 0)
      continue;
    switch (line) {
    case "exit", "quit", "q":
      return 0;
    case "?", "help":
      printHelp();
      break;
    case "info":
      printInfo(cfg);
      break;
    case "conf":
      writeln(generate(cfg));
      break;
    case "apply":
      applyFirewall(cfg);
      break;
    default:
      writeln(line ~ ": command not found...");
      break;
    }
  }
}

/** Whether `firewall-cmd` is available on this host. */
bool firewalldEnabled() {
  auto result = execute(["which", "firewall-cmd"], null, Config.none);
  return result.status == 0 && result.output.strip().length > 0;
}

/** Whether the current process runs as uid 0. */
bool isRoot() {
  auto result = execute(["id"], null, Config.none);
  return result.output.indexOf("uid=0(root)") >= 0;
}

/** Prints the http ports declared in the config. */
void printInfo(Container container) {
  writeln("http ports:" ~ container.ports().map!(p => p.to!string).join(" "));
}

/** Renders the firewalld zone fragment for the declared ports. */
string generate(Container container) {
  return renderFirewallConf(container.ports());
}

/** Applies the declared ports via `firewall-cmd --permanent`. */
void applyFirewall(Container container) {
  if (!firewalldEnabled()) {
    writeln("Cannot find firewalld utilities,firewall config abort.");
    return;
  }
  auto ports = container.ports();
  if (!ports.length)
    return;

  import std.stdio : write, stdout;

  write("apply http ports:" ~ ports.map!(p => p.to!string).join(" ") ~ "(y/n)?");
  stdout.flush();
  if (strip(readln()).toLower() != "y")
    return;

  string[] args = ["firewall-cmd", "--permanent", "--zone=public"];
  foreach (port; ports)
    args ~= "--add-port=" ~ port.to!string ~ "/tcp";
  if (!isRoot()) {
    writeln("Please execute the command:\n sudo " ~ args.join(" "));
    return;
  }
  writeln("executing:" ~ args.join(" "));
  auto result = execute(args, null, Config.stderrPassThrough);
  if (result.status == 0)
    writeln("firewalld changed successfully.");
  else
    writeln("firewall-cmd failed with exit code " ~ result.status.to!string ~ ".");
}

/** 打印交互式命令帮助。 */
private void printHelp() {
  writeln("Avaliable command:");
  writeln("  info        print server port");
  writeln("  conf        generate firewall configuration");
  writeln("  apply       apply server port config to firewall");
  writeln("  help        print this help conent");
}

private import std.algorithm : map;
private import std.string : indexOf, toLower;
