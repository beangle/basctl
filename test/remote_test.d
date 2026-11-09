/* Copyright (C) 2026 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

/** Unit tests for BAS_PRINCIPAL / BAS_TOKEN. */
module test.remote_test;

import bas.remote : RemoteConfig, agentChannelUrl, bearerCredential, isAllowedRemoteUrl,
  loadRemoteEnv, serverConfigUrl, validateRemoteConf;

import std.exception : assertThrown;
import std.process : environment;

private void clearRemote() {
  environment.remove("BAS_PRINCIPAL");
  environment.remove("BAS_TOKEN");
}

@("BAS_PRINCIPAL parses project and url") unittest {
  clearRemote();
  scope (exit) clearRemote();
  environment["BAS_PRINCIPAL"] = "openurp.prod@https://hub.example.com/bashub/";
  environment["BAS_TOKEN"] = "secret";
  auto conf = loadRemoteEnv();
  assert(conf.url == "https://hub.example.com/bashub/");
  assert(conf.project == "openurp.prod");
  assert(conf.token == "secret");
  assert(conf.complete);
  assert(serverConfigUrl(conf)
      == "https://hub.example.com/bashub/api/bashub/config/openurp.prod/server");
  assert(agentChannelUrl(conf)
      == "https://hub.example.com/bashub/api/bashub/monitor/agents/openurp.prod/channel");
  assert(bearerCredential(conf) == "openurp.prod:secret");
}

@("empty environment is offline") unittest {
  clearRemote();
  scope (exit) clearRemote();
  assert(!loadRemoteEnv().configured);
  assert(!loadRemoteEnv().complete);
}

@("partial or malformed environment is rejected") unittest {
  clearRemote();
  scope (exit) clearRemote();
  environment["BAS_PRINCIPAL"] = "openurp.prod@https://hub.example.com";
  assertThrown!Exception(loadRemoteEnv());
  environment["BAS_TOKEN"] = "secret";
  environment["BAS_PRINCIPAL"] = "openurp.prod";
  assertThrown!Exception(loadRemoteEnv());
  environment["BAS_PRINCIPAL"] = "openurp.prod@ftp://host";
  assertThrown!Exception(loadRemoteEnv());
  environment["BAS_PRINCIPAL"] = "prod@https://host";
  assertThrown!Exception(loadRemoteEnv());
}

@("remote validation rejects incomplete values") unittest {
  assertThrown!Exception(validateRemoteConf(RemoteConfig.init, "environment"));
  assertThrown!Exception(validateRemoteConf(RemoteConfig("ftp://host", "a.b", "k"), "environment"));
  validateRemoteConf(RemoteConfig("http://hub.example.com", "a.b", "k"), "environment");
  assertThrown!Exception(validateRemoteConf(RemoteConfig("https://host", "prod", "k"), "environment"));
  assertThrown!Exception(validateRemoteConf(RemoteConfig("https://host", "openurp.prod", ""), "environment"));
}

@("plain HTTP is accepted for configured hosts") unittest {
  assert(isAllowedRemoteUrl("https://hub.example.com/bashub"));
  assert(isAllowedRemoteUrl("http://hub.example.com"));
}
