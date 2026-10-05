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
 * 随二进制内嵌的资源，以及 firewalld zone 片段渲染。
 *
 * 容器的 `server.xml` / `web.xml` 由 `bas.enginecreator` 的 creator 生成（那里才需要
 * 按解压结果与多 webapp 计划渲染），本模块只服务 `firewall` 子命令与 creator 需要的
 * 内嵌资源。
 */
module bas.render;

import std.array : appender;
import std.conv : to;

/** 随二进制内嵌的资源：Tomcat 的 `catalina.properties`。 */
enum catalinaProperties = import("tomcat/conf/catalina.properties");

/** 随二进制内嵌的资源：`bas/mime.types`。 */
enum mimeTypesResource = import("bas/mime.types");

/** 渲染 firewalld zone 片段。 */
string renderFirewallConf(const(int)[] ports) {
  auto sb = appender!string;
  sb.put("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n");
  sb.put("<zone>\n");
  sb.put("  <short>Public</short>\n");
  foreach (port; ports)
    sb.put("  <port protocol=\"tcp\" port=\"" ~ port.to!string ~ "\"/>\n");
  sb.put("</zone>\n");
  return sb.data;
}
