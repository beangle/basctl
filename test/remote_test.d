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

import bas.remote : RemoteConfig, parseRemoteConf, profileControlUrl, validateRemoteConf;

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
  assert(conf.complete);
  assert(profileControlUrl(conf) == "https://hub.example.com/bashub/api/openurp.prod");
}

@("other sections do not leak into remote") unittest {
  auto conf = parseRemoteConf("[other]\nurl = https://wrong\n[remote]\nprofile = demo.prod");
  assert(conf.url == "");
  assert(conf.profile == "demo.prod");
  assert(conf.token == "");
  assert(!conf.complete);
}

@("remote validation rejects incomplete values and non-http URLs") unittest {
  assertThrown!Exception(validateRemoteConf(RemoteConfig.init, "basctl.conf"));
  assertThrown!Exception(validateRemoteConf(RemoteConfig("ftp://host", "a.b", "k"), "basctl.conf"));
  assertThrown!Exception(validateRemoteConf(RemoteConfig("https://host", "prod", "k"), "basctl.conf"));
  assertThrown!Exception(validateRemoteConf(RemoteConfig("https://host", "openurp.prod", ""), "basctl.conf"));
}
