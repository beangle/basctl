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
 * setline 入口地址：写在哪（`server.xml` 的 `<setline endpoint>` / `--endpoint`）、怎么写、最终取
 * 哪一个。
 *
 * 地址只有两个真源——配置（本 `BAS_HOME` 长期声明）与命令行（本次调用覆盖），必须收成**一个**
 * 解析入口（{@link resolveSetlineEndpoint}），否则就会出现"`doctor` 说通、`setline --sync` 说
 * 连不上"这类自相矛盾——`config.d` 用它校验配置，`doctor` / `status` / `start` / `stop` /
 * `setline` 用它取地址。没有缺省：**配了 `<setline>` 就一定要写 `<setline endpoint>`**（`config.d`
 * 在校验配置时拦下），命令行 `--endpoint` 用于"这份配置根本没启用 setline、只想渲染/对账一次"或
 * 临时覆盖。两处都没有就是没地址可拨，报错而不是替谁猜一个——没有第二种解释，也没有环境变量那
 * 一层看不见的状态。
 *
 * 写法与 setline 自己配置里的 `listen` 同构（`8080` / `127.0.0.1:8080` / `*:8080`），但**两者不是
 * 同一个值**：`listen` 是绑哪个 socket（`*` 合法），`endpoint` 是往哪拨（`*` 只能落到回环）。
 * 容器里一个绑 `*:8080`、一个拨 `127.0.0.1:8080`——所以元素上叫 endpoint，不叫 listen。
 */
module bas.endpoint;

import bas.net : canBindPort;

import std.conv : to;
import std.string : lastIndexOf, strip;

/** 入口地址：`*` / 空 host 表示监听所有地址（探测时走回环）。 */
struct ListenEndpoint {
  string host;
  ushort port;

  /** 展示用写法：`*:8080` 或 `127.0.0.1:8080`。 */
  string toString() const {
    return (host.length ? host : "*") ~ ":" ~ port.to!string;
  }
}

/** 入口地址的出处，用于展示（`doctor` 的 source 列）。 */
enum SetlineEndpointSource {
  /** `--endpoint`：只对本次调用有效。 */
  endpointFlag,
  /** `server.xml` 的 `<setline endpoint>`：本 `BAS_HOME` 声明自己拨哪扇门。 */
  serverXml
}

/** 出处的展示名，与 `basctl doctor` 的 source 列同一套说法。 */
string sourceName(SetlineEndpointSource source) {
  final switch (source) {
  case SetlineEndpointSource.endpointFlag:
    return "--endpoint";
  case SetlineEndpointSource.serverXml:
    return "server.xml";
  }
}

/** 解析结果：地址与它的出处。 */
struct SetlineEndpointChoice {
  ListenEndpoint endpoint;
  SetlineEndpointSource source;
}

/**
 * 入口地址的唯一解析入口：`--endpoint` > `server.xml` 的 `<setline endpoint>`。
 *
 * 配置声明本 `BAS_HOME` 长期拨哪扇门（`<setline>` 出现时它在解析配置那一步就是必填的），命令行
 * 覆盖单次调用或给一份没启用 setline 的配置临时指路。**没有缺省**：两处都没有就报错——
 * `127.0.0.1:8080` 这种"大家都这么写"的约定放进代码，只会在端口一改时变成谁也没注意的错地址；
 * 写在配置里则是看得见的一行（样例 `server.xml` 就带着它）。
 *
 * 两个入参都是原始写法（空串表示没写），非法写法抛 `Exception`（消息里带原写法）。
 */
SetlineEndpointChoice resolveSetlineEndpoint(string endpointFlag, string fromServerXml) {
  auto flag = strip(endpointFlag);
  if (flag.length)
    return SetlineEndpointChoice(parseListenEndpoint(flag), SetlineEndpointSource.endpointFlag);

  auto configured = strip(fromServerXml);
  if (configured.length)
    return SetlineEndpointChoice(parseListenEndpoint(configured), SetlineEndpointSource.serverXml);

  throw new Exception("No setline entry address: set <setline endpoint=\"host:port\"/>"
      ~ " in server.xml, or pass --endpoint=<addr>.");
}

/**
 * 解析 setline 的 listen 写法：`8080` / `*:8080` / `127.0.0.1:8080`。非法写法抛异常。
 *
 * 裸端口与 setline 同义，绑回环；`*` 落成空 host，表示监听所有地址。
 */
ListenEndpoint parseListenEndpoint(string value) {
  auto text = strip(value);
  auto colon = text.lastIndexOf(":");
  if (colon < 0) {
    return ListenEndpoint("127.0.0.1", parseListenPort(text));
  }
  auto host = text[0 .. colon];
  return ListenEndpoint(host == "*" ? "" : host, parseListenPort(text[colon + 1 .. $]));
}

/** 探测/连接用的实际地址：监听所有地址时只能用回环探自己。 */
string probeHost(ListenEndpoint endpoint) {
  auto host = strip(endpoint.host);
  if (host.length == 0 || host == "0.0.0.0" || host == "::")
    return "127.0.0.1";
  return host;
}

/**
 * 入口是否空闲：能独立 `bind` 一次就说明没有进程在监听（随即释放，不占端口）。
 *
 * `*` / 空 host 监听所有地址，绑定同一地址才探得准，语义见 {@link bas.net.canBindPort}。
 */
bool portFree(ListenEndpoint endpoint) @trusted {
  return canBindPort(endpoint.host, endpoint.port);
}

/** 解析端口号，越界即抛异常。 */
private ushort parseListenPort(string text) {
  int port;
  try
    port = strip(text).to!int;
  catch (Exception)
    throw new Exception("Invalid listen port: " ~ text);
  if (port <= 0 || port > 65535)
    throw new Exception("Invalid listen port: " ~ text);
  return cast(ushort) port;
}
