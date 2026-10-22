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

/** Unit tests for bas.hub：控制面地址到 WebSocket 拨号地址的转换。 */
module test.hub_test;

import bas.hub;

import std.exception : assertThrown;

@("the dial address only changes http(s) to ws(s)") unittest {
  assert(agentUrl("https://sas.openurp.net/api/bashub/monitor/agents/demo.prod/channel")
      == "wss://sas.openurp.net/api/bashub/monitor/agents/demo.prod/channel");
  assert(agentUrl("http://127.0.0.1:8080/api/bashub/monitor/agents/demo.prod/channel")
      == "ws://127.0.0.1:8080/api/bashub/monitor/agents/demo.prod/channel");
  // 已经是 websocket 的地址就原样留着（本地调试直接写 ws:// 更省事）
  assert(agentUrl("ws://127.0.0.1:8080/api/bashub/monitor/agents/demo.prod/channel")
      == "ws://127.0.0.1:8080/api/bashub/monitor/agents/demo.prod/channel");
  assert(agentUrl("wss://sas.openurp.net/api/bashub/monitor/agents/demo.prod/channel")
      == "wss://sas.openurp.net/api/bashub/monitor/agents/demo.prod/channel");
  // 认不出的 scheme 直接报错，不猜
  assertThrown(agentUrl("ftp://sas.openurp.net/api/bashub/monitor/agents/demo.prod/channel"));
  assertThrown(agentUrl("sas.openurp.net/api/bashub/monitor/agents/demo.prod/channel"));
}

@("remote plaintext WebSocket is rejected, loopback is kept for local debugging") unittest {
  assertThrown(agentUrl("http://hub.example.com/api/bashub/monitor/agents/demo.prod/channel"));
  assertThrown(agentUrl("ws://hub.example.com/api/bashub/monitor/agents/demo.prod/channel"));
  assertThrown(agentUrl("ws://127.0.0.1.evil.com/api/bashub/monitor/agents/demo.prod/channel"));
  assert(agentUrl("http://127.0.0.1:8080/api/bashub/monitor/agents/demo.prod/channel")
      == "ws://127.0.0.1:8080/api/bashub/monitor/agents/demo.prod/channel");
  assert(agentUrl("wss://sas.openurp.net/api/bashub/monitor/agents/demo.prod/channel")
      == "wss://sas.openurp.net/api/bashub/monitor/agents/demo.prod/channel");
}
