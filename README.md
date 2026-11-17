# snmp2iec104

Gateway from SNMP (v1/v2c/v3, polling and traps) to IEC 60870-5-104, built on
Erlang/OTP and [erl60870](https://github.com/Hoernchen20/erl60870).

> **Status:** phase 6, REST API with users, sessions and roles (`/api/v1`, OpenAPI at `/api/v1/openapi.json`) on top of traps and informs, SNMP polling (v1/v2c/v3) and the IEC 104 side. See [docs/DESIGN.md](docs/DESIGN.md)
> for the architecture and the implementation phases.

## Layout

| App | Role |
|---|---|
| `snmp2iec104` | application entry point, root supervisor `s2i_sup` |
| `s2i_core` | config model, validation, transforms, routing (library) |
| `s2i_snmp` | SNMP manager side: snmpm, one process per device (polling, traps) (library) |
| `s2i_iec` | IEC 104 server side on top of erl60870 (library) |
| `s2i_web` | REST API, web UI, WebSocket debugging (library) |

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

The REST API listens on `http://127.0.0.1:8080/api/v1` (`s2i_web` `http` /
`https` in `config/sys.config`). On the first start an `admin` user is
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
