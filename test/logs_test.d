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
 * `bas.logs` 的测试：实例名当目录名的校验、尾部与区间的读法、`-f` 的跟随游标、命令行解析。
 *
 * 跟随（`-f`）不启线程：把 {@link readNewLines} 的游标直接推着走，测的就是循环里那几行真正的
 * 规则——只吃完整行、轮转后从头读。
 */
module test.logs_test;

import bas.logs;

import std.array : join;
import std.conv : to;
import std.file : mkdirRecurse, tempDir, write;
import std.path : buildPath;
import std.stdio : File;

/** 往文件末尾追加（`std.file.append` 对字符串不友好，直接用追加模式打开）。 */
private void appendText(string path, string text) {
  auto file = File(path, "a");
  scope (exit) file.close();
  file.write(text);
}

@("consoleLog points at logs/<instance>/console.out") unittest {
  assert(consoleLog("/opt/bas", "tools.server1") == "/opt/bas/logs/tools.server1/console.out");
}

@("plainName treats the instance as one directory name, not a path") unittest {
  assert(plainName("tools.server1"));
  assert(!plainName(""));
  assert(!plainName("."));
  assert(!plainName(".."));
  assert(!plainName("../etc/passwd"));
  assert(!plainName("a/b"));
  assert(!plainName("a\\b"));
}

@("parseLogArgs takes one instance, -n and -f") unittest {
  // 每次都从干净的 options 起（`runLogs` 也只解析一次）；第二个位置参数就该是错误
  LogOptions options;
  assert(parseLogArgs(["tools.server1"], options));
  assert(options.instance == "tools.server1");
  assert(options.lines == defaultTailLines);
  assert(!options.follow);

  options = LogOptions.init;
  assert(parseLogArgs(["tools.server1", "-n", "10", "-f"], options));
  assert(options.instance == "tools.server1");
  assert(options.lines == 10 && options.follow);

  options = LogOptions.init;
  assert(parseLogArgs(["--lines=7", "tools.server1"], options));
  assert(options.lines == 7 && options.instance == "tools.server1");

  // 缺实例、多实例、越界行数、认不出的选项都不接受
  assert(rejects([]));
  assert(rejects(["-n", "5"]));
  assert(rejects(["a.b", "c.d"]));
  assert(rejects(["a.b", "-n"]));
  assert(rejects(["a.b", "-n", "0"]));
  assert(rejects(["a.b", "-n", (maxLogLines + 1).to!string]));
  assert(rejects(["a.b", "--lines=x"]));
  assert(rejects(["a.b", "--watch"]));
}

/** 这组参数该被拒吗（`parseLogArgs` 要 `ref`，这里给一个一次性的 options）。 */
private bool rejects(string[] args) {
  LogOptions options;
  return !parseLogArgs(args, options);
}

@("readTail reads the last lines, and all of them when n exceeds the file") unittest {
  auto dir = buildPath(tempDir(), "basctl-logs-tail");
  mkdirRecurse(dir);
  auto path = buildPath(dir, "console.out");
  write(path, "one\ntwo\nthree\nfour\nfive\n");

  auto window = readTail(path, 2);
  assert(window.total == 5, window.total.to!string);
  assert(window.lines.join(",") == "four,five", window.lines.join(","));

  assert(readTail(path, 99).lines.length == 5);
  assert(readTail(path, 1).lines.join(",") == "five");
  // 文件不存在（实例还没起过）是一个空窗口，不是异常
  assert(readTail(buildPath(dir, "nothing.out"), 5).lines.length == 0);
}

@("readNewLines keeps only complete lines, and starts over after a roll") unittest {
  auto dir = buildPath(tempDir(), "basctl-logs-follow");
  mkdirRecurse(dir);
  auto path = buildPath(dir, "console.out");
  write(path, "one\n");

  ulong cursor;
  bool rotated;
  auto first = readNewLines(path, cursor, rotated);
  assert(first.join(",") == "one", first.join(","));
  assert(!rotated);
  assert(cursor == 4, cursor.to!string);

  // 没有新内容就是空的，游标不动
  assert(readNewLines(path, cursor, rotated).length == 0);
  assert(cursor == 4);

  // 半行（还没换行）先留着：`-f` 不该把一行日志截成两段
  appendText(path, "partial");
  assert(readNewLines(path, cursor, rotated).length == 0, "半行不该输出");
  assert(cursor == 4, cursor.to!string);

  // 补上剩余部分与下一行，两行都出来
  appendText(path, "-done\ntwo\n");
  auto rest = readNewLines(path, cursor, rotated);
  assert(rest.join(",") == "partial-done,two", rest.join(","));
  assert(cursor == 4 + 13 + 4, cursor.to!string); // one\n + partial-done\n + two\n

  // 日志滚动：文件被换成新的、变短了，从头读并报 rotated
  write(path, "fresh\n");
  auto after = readNewLines(path, cursor, rotated);
  assert(rotated, "文件变短就是轮转");
  assert(after.join(",") == "fresh", after.join(","));
}

@("runLogs reports a missing instance instead of throwing") unittest {
  auto home = buildPath(tempDir(), "basctl-logs-missing");
  mkdirRecurse(home);
  assert(runLogs(home, ["tools.server1"]) == 1);
  assert(runLogs(home, ["../conf"]) == 1, "路径不是实例名");
  assert(runLogs(home, []) == 1, "缺实例参数");
}
