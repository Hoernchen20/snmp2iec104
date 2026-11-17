# snmp2iec104

Gateway from SNMP (v1/v2c/v3, polling and traps) to IEC 60870-5-104, built on
Erlang/OTP and [erl60870](https://github.com/Hoernchen20/erl60870).

> **Status:** phase 8, MIB library (upload, compile, OID names in the UI) on
> top of the web UI with live debugging, the REST API with users and roles,
> traps and informs, SNMP polling (v1/v2c/v3) and the IEC 104 side. See
> [docs/DESIGN.md](docs/DESIGN.md) for the architecture and the
> implementation phases.

## Try it with Docker

Needs only Docker with Compose v2; everything else is built in the image.

```sh
git clone https://github.com/Hoernchen20/snmp2iec104.git
cd snmp2iec104
docker compose up --build -d      # first build takes a few minutes
```

Open <http://localhost:8080> and log in as `admin` / `changeme` (you are asked
for a new password). The stack also runs a demo SNMP agent (net-snmp, host
`demo-agent`, v2c community `public`, v3 user `demo` with SHA/AES and
passphrase `demopassword`).

For a ready-made setup, import [docker/demo/config.json](docker/demo/config.json)
on the Configuration page (Backup → Import), then Activate. It contains:

- IEC server `scada`: IEC 104 on port 2404, common address 1
- profile `net-snmp-host` and device `demo-agent`:

  | IOA | Point | Source |
  |---|---|---|
  | 1000 | `M_ME_TF_1` uptime in s | `sysUpTime.0` |
  | 1001 | `M_ME_TF_1` 1 min load | `laLoadInt.1` / 100 |
  | 1010 / 1020 | `M_SP_TB_1` interface up (`lo` / `eth0`) | `ifOperStatus`, `linkDown` / `linkUp` traps |
  | 1011 / 1021 | `M_ME_TF_1` received bytes/s (`lo` / `eth0`) | `ifInOctets` (rate) |

Connect an IEC 104 master (e.g. QTester104) to `127.0.0.1:2404`, common
address 1. To send traps from the demo agent:

```sh
docker compose exec demo-agent send-traps down 2   # linkDown for ifIndex 2 (eth0)
docker compose exec demo-agent send-traps up 2     # also: cold, inform
```

The polls every 5 s read the real interface state again, so a `linkDown`
shows up in the live debugging view and in the IEC 104 events, but does not
last.

| Port (host) | Container | Variable |
|---|---|---|
| 8080/tcp web UI and REST API | 8080 | `S2I_HTTP_PORT` |
| 2404/tcp IEC 104 | 2404 | `S2I_IEC_PORT` |
| 1162/udp SNMP traps and informs | 162 | `S2I_TRAP_PORT` |

All ports are published on `127.0.0.1` only. To reach the gateway from
other machines (real devices, an IEC 104 master on the network), set
`S2I_BIND=0.0.0.0` and send traps to port 1162 of the host (or set
`S2I_TRAP_PORT=162`). Put these variables in a `.env` file next to
`compose.yaml`. An IEC server configured in the UI must listen on port 2404
in the container, which is the default. To publish more servers, add ports to
`compose.yaml`.

The configuration, users and the MIB cache are kept in the volume `data`, and
the key for the stored SNMP secrets in the volume `etc`.
`docker compose down -v` deletes both and starts from scratch, including
the initial `changeme` password. Logs: `docker compose logs -f gateway`;
Erlang shell: `docker compose exec gateway bin/snmp2iec104 remote_console`.

## Releases

Pushing a tag `vX.Y.Z` (equal to the release version in `rebar.config`) runs
the [release workflow](.github/workflows/release.yml): the CI checks, then the
[Dockerfile](Dockerfile) natively on amd64 and arm64. It publishes:

- the image `ghcr.io/hoernchen20/snmp2iec104:X.Y.Z` (also `X.Y` and `latest`)
- a GitHub release with `snmp2iec104-X.Y.Z-<debian>-<arch>.tar.gz` and
  `SHA256SUMS`: a self-contained release, ERTS included, for that Debian
  release (or a newer one with the same libssl). Unpack it, adjust
  `releases/X.Y.Z/sys.config`, and run `bin/snmp2iec104 foreground`.

The same build runs locally: `docker build -t snmp2iec104 .` for the image,
and `docker buildx build --target artifact -o dist .` for the tarball.

## Layout

| App | Role |
|---|---|
| `snmp2iec104` | application entry point, root supervisor `s2i_sup` |
| `s2i_core` | config model, validation, transforms, routing (library) |
| `s2i_snmp` | SNMP manager side: snmpm, one process per device (polling, traps), MIB library (library) |
| `s2i_iec` | IEC 104 server side on top of erl60870 (library) |
| `s2i_web` | REST API, web UI, WebSocket debugging (library) |
| `frontend/` | React + TypeScript source of the web UI, built into `apps/s2i_web/priv/www` |
| `Dockerfile`, `compose.yaml`, `docker/` | image and release build, test setup with a demo SNMP agent |

## Development

Requires Erlang/OTP 27 or newer and rebar3.

```sh
rebar3 compile
rebar3 check      # compile + eunit + xref + dialyzer
rebar3 ct         # common_test suites (run on their own)
rebar3 shell      # boots the gateway
rebar3 release    # builds _build/default/rel/snmp2iec104 (dev mode, uses the local OTP)
rebar3 as prod release   # self-contained release with ERTS (what the Dockerfile builds)
```

The SNMP manager listens on UDP 162 (the trap port) by default, which needs
`CAP_NET_BIND_SERVICE` or a port redirect. As an unprivileged user, set
`s2i_snmp` `port` in `config/sys.config` or override it on start, e.g.
`ERL_FLAGS="-s2i_snmp port 1162" rebar3 shell`.

The web UI and the REST API listen on `http://127.0.0.1:8080` (UI) and
`/api/v1` (`s2i_web` `http` / `https` in `config/sys.config`). On the first start an `admin` user is
created; its password comes from `S2I_ADMIN_PASSWORD`, `s2i_web`
`admin_password`, or is generated into `data/initial_admin_password`, and
must be changed on the first login:

```sh
curl -c jar -H 'X-Requested-With: curl' -H 'content-type: application/json' \
     -d '{"username":"admin","password":"..."}' http://127.0.0.1:8080/api/v1/login
curl -b jar -H 'X-Requested-With: curl' -H 'content-type: application/json' \
     -d '{"current_password":"...","new_password":"..."}' http://127.0.0.1:8080/api/v1/me/password
curl -b jar http://127.0.0.1:8080/api/v1/status
```

### Web UI

The UI is a separate build (Node.js 20 or newer); the gateway serves the
result from `apps/s2i_web/priv/www` (not committed). Build it before
`rebar3 release`:

```sh
cd frontend
npm ci
npm run build     # typecheck + production build into apps/s2i_web/priv/www
npm test          # Vitest + React Testing Library
npm run dev       # dev server on :5173, proxies /api and /ws to 127.0.0.1:8080
npm run gen:api   # regenerate src/api/schema.d.ts after API changes (needs rebar3 compile)
```

Pages: status (devices, IEC servers and their redundancy groups), devices /
profiles / IEC servers (forms generated from the API schemas, or raw JSON),
configuration (staged changes, validate, activate, versions and rollback,
export / import, audit log), live debugging, SNMP GET / walk, MIBs, users.

Live debugging uses the WebSocket `/ws` (session cookie, same origin):
values of a device (raw SNMP value → IEC point) or of an IEC server, the SNMP
request/response trace of a device, received traps (also unmatched or from
unknown agents), IEC connections and redundancy groups, and the gateway log.

### MIBs

The gateway works on numeric OIDs; MIBs only give them names in the UI. Upload
MIB files on the MIBs page (or `POST /api/v1/mibs` with
`{"sources": ["<file text>", ...]}`), in any order: each module is compiled
with OTP's `snmpc` once the modules it imports are there. Modules that fail to
compile are listed with the compiler's message. The MIBs that ship with OTP
(`SNMPv2-MIB`, `RFC1213-MIB`, …) are built in. Compiled modules are cached in
`data/snmp/mibs` (`s2i_snmp` `mib_dir`); the sources are stored in Mnesia but
are not part of configuration exports.
