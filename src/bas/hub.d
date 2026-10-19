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
 * 控制通道（bashub）的拨号地址。
 *
 * 地址与凭证都来自同目录 `conf/basctl.conf` 的 `[remote] url/profile/token`，与 `pull`
 * 完全共用一份配置；`server.xml` 不再保存通道地址或凭证。
 */
module bas.hub;

import std.algorithm : startsWith;
import std.string : strip;

/**
 * 拨号地址：Profile 控制面地址后面拼 `/agents`，scheme 换成 WebSocket 的——`https` → `wss`、
 * `http` → `ws`（已经是 `ws` / `wss` 就原样留着）。
 */
string agentUrl(string profileControlUrl) {
  auto base = strip(profileControlUrl);
  string url;
  if (base.startsWith("https://"))
    url = "wss://" ~ base["https://".length .. $];
  else if (base.startsWith("http://"))
    url = "ws://" ~ base["http://".length .. $];
  else if (base.startsWith("wss://") || base.startsWith("ws://"))
    url = base;
  else
    throw new Exception("Invalid control url (expect http/https): " ~ base);
  return url ~ "/agents";
}
