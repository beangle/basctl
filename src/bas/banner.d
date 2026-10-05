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

/** 版本横幅与主机地址。 */
module bas.banner;

import bas.net;

import std.algorithm : sort;
import std.array : join;
import std.string : chomp;

/**
 * bas 的标志：纯 ASCII，任何字符集的终端都能显示（与 bas 引擎的 `BasVersion.ASCII_LOGO` 同一份）。
 * 图形各行的行尾空白已去掉，避免被 editorconfig 的 trim_trailing_whitespace 破坏；
 * 用 token string 原样存放，收尾换行由 chomp 去掉。
 */
string asciiLogo() {
  return q"BAS
 ____    __    ___
(  _ \  /__\  / __)
 ) _ < /(__)\ \__ \
(____/(__)(__)(___/
BAS".chomp;
}

/**
 * stdout 是否交互终端：是则在横幅里打图形，不是（重定向到日志 / 管道 / CI）只留文字。
 * POSIX 用 isatty(1)，Windows 用 GetConsoleMode，不关心字符集（图形是纯 ASCII）。
 */
bool showArt() @trusted {
  version (Windows) {
    import core.sys.windows.winbase : GetStdHandle, STD_OUTPUT_HANDLE;
    import core.sys.windows.wincon : GetConsoleMode;

    uint mode;
    return GetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), &mode) != 0;
  } else {
    import core.sys.posix.unistd : isatty;

    return isatty(1) != 0;
  }
}

/** 所有本机地址，排序后以逗号连接。 */
string hostsLine() {
  auto addresses = localAddresses();
  addresses.sort();
  return "hosts:" ~ addresses.join(",");
}

/**
 * 操作者横幅：图形 + 版本行 + 本机地址。`bas.sh version` 与 `basctl status` 都用它，
 * 图形只在交互终端出现（见 {@link showArt}），重定向到日志时退化为纯文字。
 *
 * `basVersion` 是 `conf/server.xml` 的 `<bas version>`（bas 引擎版本）；为空表示拿不到
 * server.xml，此时只显示 basctl 自身的版本，避免把 basctl 的版本误当成 bas 引擎版本。
 */
string banner(string basctlVersion, string basVersion, bool art = showArt()) {
  auto versions = basVersion.length
    ? "bas " ~ basVersion ~ "   basctl " ~ basctlVersion
    : "basctl " ~ basctlVersion;
  auto hostLine = hostsLine();
  return art
    ? asciiLogo() ~ "\n" ~ versions ~ "\n" ~ hostLine
    : versions ~ "\n" ~ hostLine;
}
