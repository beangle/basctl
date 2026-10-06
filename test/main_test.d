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

/** Unit tests for bas.main listener-snapshot parsing. */
module test.main_test;

import bas.main : extractListenPort, portsFromNetstat, portsFromSs, setlineFileListen;

import std.file : remove, write;

@("setlineFileListen reads the listen field as written") unittest {
  auto path = "/tmp/basctl-setline-file-listen.json";
  scope (exit) remove(path);

  write(path, `{"listen":"127.0.0.1:8080","adminToken":"x"}`);
  assert(setlineFileListen(path) == "127.0.0.1:8080");

  write(path, `{"listen":8080}`);
  assert(setlineFileListen(path) == "8080");

  write(path, `{"routes":{}}`);
  assert(setlineFileListen(path) == "");

  write(path, "not json");
  assert(setlineFileListen(path) == "");
}

@("extractListenPort ipv4 and bracket ipv6") unittest {
  assert(extractListenPort("127.0.0.1:8080") == "8080");
  assert(extractListenPort("[::1]:8443") == "8443");
}

@("portsFromSs finds port field") unittest {
  auto sample = "tcp LISTEN 0 128 127.0.0.1:9090 0.0.0.0:* users:((\"java\",pid=4242,fd=99))";
  auto ports = portsFromSs(sample ~ "\n", 4242);
  assert(ports == ["9090"]);
}

@("portsFromNetstat English LISTENING") unittest {
  auto sample = "  TCP    127.0.0.1:8088         0.0.0.0:0              LISTENING       805964\r";
  auto ports = portsFromNetstat(sample ~ "\n", 805964);
  assert(ports == ["8088"]);
}
