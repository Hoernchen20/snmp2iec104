# snmp2iec104

Gateway from SNMP (v1/v2c/v3, polling and traps) to IEC 60870-5-104, built on
Erlang/OTP and [erl60870](https://github.com/Hoernchen20/erl60870).

> **Status:** phase 7, web UI (React) and live debugging over WebSocket on top
> of the REST API with users and roles, traps and informs, SNMP polling
> (v1/v2c/v3) and the IEC 104 side. See [docs/DESIGN.md](docs/DESIGN.md) for
> the architecture and the implementation phases.

## Layout

| App | Role |
|---|---|
| `snmp2iec104` | application entry point, root supervisor `s2i_sup` |
| `s2i_core` | config model, validation, transforms, routing (library) |
| `s2i_snmp` | SNMP manager side: snmpm, one process per device (polling, traps) (library) |
| `s2i_iec` | IEC 104 server side on top of erl60870 (library) |
| `s2i_web` | REST API, web UI, WebSocket debugging (library) |
| `frontend/` | React + TypeScript source of the web UI, built into `apps/s2i_web/priv/www` |

## Development

Requires Erlang/OTP 27 or newer and rebar3.

```sh
rebar3 compile
rebar3 check      # compile + eunit + xref + dialyzer
rebar3 ct         # common_test suites (run on their own)
rebar3 shell      # boots the gateway
rebar3 release    # builds _build/default/rel/snmp2iec104
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
export / import, audit log), live debugging, SNMP GET / walk, users.

Live debugging uses the WebSocket `/ws` (session cookie, same origin):
values of a device (raw SNMP value → IEC point) or of an IEC server, the SNMP
request/response trace of a device, received traps (also unmatched or from
unknown agents), IEC connections and redundancy groups, and the gateway log.
