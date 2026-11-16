# snmp2iec104

Gateway from SNMP (v1/v2c/v3, polling and traps) to IEC 60870-5-104, built on
Erlang/OTP and [erl60870](https://github.com/Hoernchen20/erl60870).

> **Status:** phase 4, SNMP polling (v1/v2c/v3 incl. engine id discovery, instance resolution, reboot detection, device health and comm status) on top of the IEC 104 side. See [docs/DESIGN.md](docs/DESIGN.md)
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
