/* Copyright (C) 2026 Beangle
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

/** Unit tests for conf/basctl.conf. */
module test.remote_test;

import bas.remote : RemoteConfig, agentChannelUrl, bearerCredential, isAllowedRemoteUrl, parseRemoteConf,
  serverConfigUrl, validateRemoteConf;

import std.exception : assertThrown;

@("remote section parses url, profile and token") unittest {
  auto conf = parseRemoteConf(q"{
; control plane
[remote]
url = https://hub.example.com/bashub/
profile = openurp.prod
token = "secret"
}");
  assert(conf.url == "https://hub.example.com/bashub/");
  assert(conf.profile == "openurp.prod");
  assert(conf.token == "secret");
  assert(conf.configured);
  assert(conf.complete);
  assert(serverConfigUrl(conf)
      == "https://hub.example.com/bashub/api/bashub/config/openurp.prod/server");
  assert(agentChannelUrl(conf)
      == "https://hub.example.com/bashub/api/bashub/monitor/agents/openurp.prod/channel");
  assert(bearerCredential(conf) == "openurp.prod:secret");
}

@("other sections do not leak into remote") unittest {
  auto conf = parseRemoteConf("[other]\nurl = https://wrong\n[remote]\nprofile = demo.prod");
  assert(conf.url == "");
  assert(conf.profile == "demo.prod");
  assert(conf.token == "");
  assert(conf.configured);
  assert(!conf.complete);
}

@("an empty template is neither configured nor complete") unittest {
  auto conf = parseRemoteConf("# template\n[remote]\nurl =\nprofile =\ntoken =\n");
  assert(!conf.configured);
  assert(!conf.complete);
}

@("remote validation rejects incomplete values and insecure URLs") unittest {
  assertThrown!Exception(validateRemoteConf(RemoteConfig.init, "basctl.conf"));
  assertThrown!Exception(validateRemoteConf(RemoteConfig("ftp://host", "a.b", "k"), "basctl.conf"));
  assertThrown!Exception(validateRemoteConf(RemoteConfig("http://hub.example.com", "a.b", "k"), "basctl.conf"));
  assertThrown!Exception(validateRemoteConf(RemoteConfig("http://127.0.0.1.evil.com", "a.b", "k"), "basctl.conf"));
  assertThrown!Exception(validateRemoteConf(RemoteConfig("https://host", "prod", "k"), "basctl.conf"));
  assertThrown!Exception(validateRemoteConf(RemoteConfig("https://host", "openurp.prod", ""), "basctl.conf"));
}

@("plain HTTP is only accepted for an exact loopback host") unittest {
  assert(isAllowedRemoteUrl("https://hub.example.com/bashub"));
  assert(isAllowedRemoteUrl("http://127.0.0.1:8080"));
  assert(isAllowedRemoteUrl("http://localhost:8080"));
  assert(isAllowedRemoteUrl("http://[::1]:8080"));
  assert(!isAllowedRemoteUrl("http://hub.example.com"));
  assert(!isAllowedRemoteUrl("http://127.0.0.1.evil.com"));
  assert(!isAllowedRemoteUrl("https://user:pass@hub.example.com"));
}
