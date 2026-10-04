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

/** Unit tests for bas.pull. */
module test.pull_test;

import bas.pull : ipHeader, serverXmlUrl;

@("serverXmlUrl appends config/server.xml and tolerates trailing slashes") unittest {
  assert(serverXmlUrl("https://control.example/api") == "https://control.example/api/config/server.xml");
  assert(serverXmlUrl("https://control.example/api/") == "https://control.example/api/config/server.xml");
  assert(serverXmlUrl("https://control.example/api///") == "https://control.example/api/config/server.xml");
  assert(serverXmlUrl(" https://control.example/api ") == "https://control.example/api/config/server.xml");
}

@("ipHeader drops loopback and joins the rest with spaces") unittest {
  assert(ipHeader(["127.0.0.1", "10.0.0.1", "192.168.1.2"]) == "10.0.0.1 192.168.1.2");
  assert(ipHeader(["10.0.0.1"]) == "10.0.0.1");
  assert(ipHeader(["127.0.0.1"]) == "");
  assert(ipHeader([]) == "");
}
