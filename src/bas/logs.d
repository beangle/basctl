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
 * 实例日志的**唯一读法**：`logs/<实例>/console.out` 的定位、按行区间读取，以及 `basctl logs`。
 *
 * 两处消费者共用本模块，所以「日志在哪」「怎么数行」只写一遍：
 *
 * - `basctl logs <实例> [-n <行数>] [-f]`（人看的本地命令）；
 * - 通道的 `log:read`（控制台经 basagent 取日志，见 {@link bas.agent.logReadResult}）。
 *
 * 实例名在这里当**目录名**用，不是路径：{@link plainName} 挡掉 `../` 这类输入，否则控制台就能借
 * 日志接口读机器上任何文件。读窗口按行数上限截断（{@link maxLogLines}），一次请求不该把内存撑爆。
 *
 * 归档的旧日志在 `logs/archive/<实例>-YYYYMMDD.out`（`start` 时由
 * {@link bas.serverstatus.rollLog} 滚动），本模块只读正在写的 `console.out`——归档要人工看时
 * 直接读文件即可，不必再给一条命令。
 */
module bas.logs;

import bas.config : Server;

import core.thread : Thread;
import core.time : msecs;

import std.algorithm : sort, startsWith;
import std.array : join;
import std.conv : to;
import std.file : SpanMode, dirEntries, exists, getSize;
import std.path : baseName, buildPath;
import std.stdio : File, stderr, stdout, writeln;
import std.string : strip;

/** `-n` 的缺省值：够看清最近发生了什么，又不至于刷屏。 */
enum defaultTailLines = 50;

/** 一次最多读多少行：`-n` 与通道的 `log:read` 共用同一个上限，别让一条命令把内存撑爆。 */
enum maxLogLines = 2000;

/** 跟随的轮询间隔：本地文件，半秒一次足够快，也不至于空转烧 CPU。 */
private enum followInterval = 500.msecs;

/** 实例控制台日志：`logs/<实例>/console.out`（`servers/<实例>/logs` 是指向它的软链）。 */
string consoleLog(string basHome, string instance) {
  return buildPath(basHome, "logs", instance, "console.out");
}

/** 实例控制台日志（按 `farm.server` 限定的实例名）。 */
string consoleLog(string basHome, Server server) {
  return consoleLog(basHome, server.qualifiedName);
}

/**
 * 实例名是不是一个普通目录名（挡掉 `../etc/passwd` 这类输入）。
 *
 * 实例名一律是 `<farm>.<server>`，只会落在 `logs/` 下一层，所以这个判断就是「不含路径分隔符、
 * 不是 `.` / `..`」——多一条白名单规则就是多一处要和命名保持同步的地方。
 */
bool plainName(string name) @safe pure nothrow {
  if (!name.length || name == "." || name == "..")
    return false;
  foreach (ch; name) {
    if (ch == '/' || ch == '\\' || ch == '\0')
      return false;
  }
  return true;
}

/** 一个窗口：`total` 是文件总行数（调用方据此翻页），`lines` 是 `from`–`to` 那一段（1 基、含两端）。 */
struct LogWindow {
  long total;
  string[] lines;
}

/** 数文件有多少行；读不到（不存在、没权限）返回 0——日志读不动不该让调用方炸掉。 */
long countLines(string path) {
  if (!exists(path))
    return 0;
  long total;
  try {
    auto file = File(path, "r");
    scope (exit) file.close();
    foreach (line; file.byLine)
      total++;
  } catch (Exception) {
    return 0;
  }
  return total;
}

/** 读 `from`–`to` 那一段（1 基、含两端）；文件不存在就是空窗口。 */
LogWindow readLogWindow(string path, long from, long to) {
  LogWindow window;
  if (!exists(path))
    return window;
  auto file = File(path, "r");
  scope (exit) file.close();
  foreach (line; file.byLine) {
    window.total++;
    if (window.total >= from && window.total <= to)
      window.lines ~= line.idup;
  }
  return window;
}

/** 读最后 `n` 行。`console.out` 每次起实例时滚动，扫两遍没有代价。 */
LogWindow readTail(string path, long n) {
  auto total = countLines(path);
  if (total <= 0)
    return LogWindow.init;
  auto from = total > n ? total - n + 1 : 1;
  return readLogWindow(path, from, total);
}

/**
 * 跟随一个正在写的文件：返回自 `cursor` 起新写完的行，并把 `cursor` 推过它们。
 *
 * 只吃**完整行**（以 `\n` 结尾）：最后那半行等它写完再来读，否则 `-f` 会把一行日志截成两段。
 * `cursor` 比文件还大是**轮转**（旧文件改名归档、新文件从空开始），从头读并置 `rotated`。
 */
string[] readNewLines(string path, ref ulong cursor, out bool rotated) {
  string[] lines;
  rotated = false;
  if (!exists(path)) {
    cursor = 0;
    return lines;
  }
  auto size = getSize(path);
  if (size < cursor) {
    cursor = 0;
    rotated = true;
  }
  if (size == cursor)
    return lines;

  auto file = File(path, "r");
  scope (exit) file.close();
  file.seek(cursor.to!long);
  while (true) {
    auto line = file.readln();
    // readln 的返回值指向可复用的内部缓冲：留下之前必须拷一份；不完整的一行不推进游标
    if (!line.length || line[$ - 1] != '\n')
      break;
    cursor += line.length;
    lines ~= stripEol(line).idup;
  }
  return lines;
}

/** `basctl logs` 的位置参数与选项。 */
struct LogOptions {
  string instance;
  long lines = defaultTailLines;
  bool follow;
}

/**
 * `basctl logs [server.xml] <实例> [-n <行数>] [-f]`：打印实例日志的尾部；`-f` 持续跟随
 * （Ctrl-C 退出，和 `tail -f` 一样，没有别的退出方式）。
 *
 * `basHome` 由调用方给（`main` 从配置文件路径推导），这里只认 `<BAS_HOME>/logs/<实例>` 这一处，
 * 不猜、不搜索。
 */
int runLogs(string basHome, string[] args) {
  LogOptions options;
  if (!parseLogArgs(args, options)) {
    logsUsage();
    return 1;
  }
  if (!plainName(options.instance)) {
    stderr.writeln("Invalid instance name: " ~ options.instance ~ " (expect <farm>.<server>).");
    return 1;
  }

  auto path = consoleLog(basHome, options.instance);
  if (!exists(path)) {
    stderr.writeln("No log for " ~ options.instance ~ ": " ~ path ~ " does not exist.");
    auto known = loggedInstances(basHome);
    if (known.length)
      stderr.writeln("Instances with logs: " ~ known.join(", "));
    return 1;
  }

  foreach (line; readTail(path, options.lines).lines)
    writeln(line);
  if (!options.follow) {
    stdout.flush();
    return 0;
  }

  auto cursor = getSize(path);
  writeln("==> following " ~ path ~ " (Ctrl-C to stop)");
  stdout.flush();
  while (true) {
    Thread.sleep(followInterval);
    bool rotated;
    auto fresh = readNewLines(path, cursor, rotated);
    if (rotated)
      writeln("==> log rolled over, following the new file");
    foreach (line; fresh)
      writeln(line);
    if (fresh.length || rotated)
      stdout.flush();
  }
}

/** `basctl logs` 的用法。 */
void logsUsage() {
  stderr.writeln("Usage: basctl logs [server.xml] <farm.server> [-n <lines>] [-f]");
  stderr.writeln("  Prints the tail of $BAS_HOME/logs/<farm.server>/console.out");
  stderr.writeln("  (default last " ~ defaultTailLines.to!string ~ " lines, at most " ~ maxLogLines.to!string ~ ");");
  stderr.writeln("  -f/--follow keeps printing new lines until you stop it (Ctrl-C).");
}

/**
 * 解析命令行：`<实例>` 一个位置参数，`-n <行数>` / `--lines=<行数>`，`-f` / `--follow`。
 * 给错返回 false，由 {@link runLogs} 打用法。
 */
bool parseLogArgs(string[] args, ref LogOptions options) {
  size_t i;
  while (i < args.length) {
    auto arg = args[i];
    if (arg == "-f" || arg == "--follow") {
      options.follow = true;
      i++;
    } else if (arg == "-n" || arg == "--lines") {
      if (i + 1 >= args.length || !parseLineCount(args[i + 1], options.lines))
        return false;
      i += 2;
    } else if (arg.startsWith("--lines=")) {
      if (!parseLineCount(arg["--lines=".length .. $], options.lines))
        return false;
      i++;
    } else if (arg.startsWith("-")) {
      return false;
    } else if (!options.instance.length) {
      options.instance = arg;
      i++;
    } else {
      return false;
    }
  }
  return options.instance.length > 0;
}

private:

/** `-n` 的取值：正整数且不超过 {@link maxLogLines}。 */
private bool parseLineCount(string text, ref long lines) {
  long value;
  try
    value = text.strip.to!long;
  catch (Exception)
    return false;
  if (value <= 0 || value > maxLogLines)
    return false;
  lines = value;
  return true;
}

/** `logs/` 下有日志的实例名（`archive` 是归档目录，不是实例），供「找不到实例」时提示。 */
private string[] loggedInstances(string basHome) {
  string[] names;
  auto dir = buildPath(basHome, "logs");
  if (!exists(dir))
    return names;
  foreach (entry; dirEntries(dir, SpanMode.shallow)) {
    auto name = baseName(entry.name);
    if (entry.isDir && name != "archive" && exists(consoleLog(basHome, name)))
      names ~= name;
  }
  names.sort();
  return names;
}

/** 去掉行尾的 `\n` 与 `\r`（日志可能是 Windows 上写出来的）。 */
private string stripEol(string line) @safe pure nothrow {
  auto end = line.length;
  if (end && line[end - 1] == '\n')
    end--;
  if (end && line[end - 1] == '\r')
    end--;
  return line[0 .. end];
}
