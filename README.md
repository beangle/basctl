# basctl

`basctl` is the local control CLI for a Beangle Bas server, written in D. The same
repository also builds `basagent`, which pulls configuration and maintains an
outbound control channel.

`basctl` turns `conf/server.xml` into runnable Tomcat instances: it resolves webapps
(`gav://`, `http(s)://`, or local paths), creates instance directories and jstart
launch specs, and renders the container's `server.xml` / `web.xml`. It can also start
instances by farm and provides status, configuration checks, and firewall helpers.

## Documentation

| Document | Contents |
|---|---|
| [docs/features.md](docs/features.md) | Features, core model, directory layout, `make` modes, jstart relationship, boundaries |
| [docs/usage.md](docs/usage.md) | Installation, quick start, commands, common workflows, environment, troubleshooting |
| [docs/proxy.md](docs/proxy.md) | `basctl proxy`: bundle contents, HAProxy/Nginx differences, local apply |
| [docs/start.md](docs/start.md) | `start` flow and generated jstart spec |
| [docs/run.md](docs/run.md) | `run`: embedded single-webapp mode |
| [docs/server-info.md](docs/server-info.md) | `server.info` format, lifecycle, dynamic port allocation |
| [docs/engine-creator.md](docs/engine-creator.md) | Engine creator protocol (`jstart [engine] init`) |
| [docs/channel.md](docs/channel.md) | basagent to bashub reporting and control channel |
| [docs/channel-protocol.md](docs/channel-protocol.md) | Control-channel protocol and extension rules |
| [scripts/README.md](scripts/README.md) | deb / rpm packaging |
| [docs/release-0.0.2.md](docs/release-0.0.2.md) | 0.0.2 release notes |

## Versions

The three versions are independent:

| Version | Declared in | Meaning |
|---|---|---|
| basctl | compile-time constant (`basctl version`) | CLI release, independent of the Bas engine |
| bas | `<bas version>` in `conf/server.xml` | `beangle-bas-engine` / `beangle-bas-juli` version |
| Container | `<engine version>` | Tomcat distribution, Undertow servlet, or Jetty version |

`<engine type>` selects the container and matches a section in `engines.ini`:
`tomcat-server` uses the full distribution for multiple apps; `tomcat`, `undertow`,
and `jetty` are embedded single-app modes.

Default dependencies are embedded from [resources/engines.ini](resources/engines.ini).
`{version}` and `{bas}` are expanded from the versions above. Extra `<engine><jar>`
entries are merged with the defaults: the same `groupId:artifactId` overrides,
otherwise it is appended.

## Configuration

`conf/server.xml` follows [resources/bas-1.0.0.xsd](resources/bas-1.0.0.xsd): root
element `<bas>`, lowercase hyphenated elements and attributes.

The published schema is <http://beangle.github.io/schema/bas-1.0.0.xsd>. Add
`xsi:noNamespaceSchemaLocation` to the root element for IDE completion and validation.

## Build and test

Requirements:

- `ldc2` >= 1.32 and `dub` >= 1.34
- `basagent` requires OpenSSL 3.x for `wss://`; `basctl` does not link OpenSSL or vibe
- `make`, `resolve`, `start`, and `run` require `jstart`; `basctl doctor` reports it
  as an optional check

```sh
dub build -c basctl --build=release-nobounds --compiler=ldc2
dub build -c basagent --build=release-nobounds --compiler=ldc2
dub test --compiler=ldc2
```

Artifacts are `target/basctl` and `target/basagent`. Tests live in `test/`, one
`*_test.d` per source module, using D `unittest` with named `@("...")` cases.

Packaging builds one deb/rpm containing `/usr/bin/basctl`, `/usr/bin/basagent`, and
`/var/lib/bas/bin/*.sh`. See [scripts/README.md](scripts/README.md). The version comes
from `basctlVersion` in `src/bas/versioninfo.d` and matches `basctl version`.

## License

GPL-3.0. See [LICENSE](LICENSE).
