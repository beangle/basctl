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
 * setline 管理口：一个**端口**，不是地址。
 *
 * basctl 与 setline 之间只有一条路——往管理口（setline 配置里的 `adminListen`）拨 HTTP 推路由、
 * 读路由表，而管理口按 setline 自己的规矩只认回环来的写（对端与 Host 都必须是回环），所以
 * basctl 永远拨 `127.0.0.1:<port>`。写别的 host 进去只会换回 403：那是个看着能配、实际必然失败
 * 的旋钮，所以这里只有端口这一个值。
 *
 * 端口只有一个来源：`conf/server.xml` 的 `<setline port>`。没有缺省、也没有命令行覆盖——地址（这里
 * 是端口）是这台机器上的一件事实，写进配置才看得见，改的时候 diff 里也看得见。
 *
 * 解析仍然只有这一个入口（{@link resolveSetlinePort}），`config.d` / `doctor` / `status` /
 * `start` / `stop` / `setline` 都从这里取值，否则就会出现"`doctor` 说通、`setline` 说连不上"这类
 * 自相矛盾。
 */
module bas.endpoint;

import bas.net : canBindPort;

import std.conv : to;
import std.string : strip;

/** 管理口的拨号地址：`127.0.0.1:<port>`（展示与连接都用它）。 */
string adminAddress(ushort port) @safe pure {
  return "127.0.0.1:" ~ port.to!string;
}

/**
 * 管理端口的唯一解析入口：`server.xml` 的 `<setline port>`，没有第二个来源。
 *
 * 入参是配置里的原始写法（空串表示没写），非法写法抛 `Exception`（消息里带原写法）。**没有缺省**：
 * 没写就报错——把 setline 的缺省 `10080` 抄进 basctl，只会在端口一改时变成谁也没注意的错端口；
 * 写在配置里则是看得见的一行（样例 `server.xml` 就带着它）。
 */
ushort resolveSetlinePort(string fromServerXml) {
  auto configured = strip(fromServerXml);
  if (!configured.length)
    throw new Exception("No setline admin port: set <setline port=\"10080\"/> in server.xml.");
  return parseSetlinePort(configured);
}

/** 解析管理端口：`1`..`65535`，非法写法抛异常（消息里带原写法）。 */
ushort parseSetlinePort(string value) {
  int port;
  try
    port = strip(value).to!int;
  catch (Exception)
    throw new Exception("Invalid setline port: " ~ value);
  if (port <= 0 || port > 65535)
    throw new Exception("Invalid setline port: " ~ value);
  return cast(ushort) port;
}

/**
 * 管理口是否闲着：能独立 `bind` 一次回环上的这个端口就说明没人在听（随即释放，不占端口）。
 *
 * 按回环探，因为 setline 的管理口要么绑回环、要么绑所有地址——两种情况在这个端口上都会被这次
 * `bind` 撞见，语义见 {@link bas.net.canBindPort}。
 */
bool portFree(ushort port) @trusted {
  return canBindPort("127.0.0.1", port);
}
