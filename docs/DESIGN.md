# snmp2iec104 — Design

Status: **draft, pre-implementation.** Scope of v1: monitoring direction only,
SNMP → IEC 60870-5-104.

## 1. Scope and goals

- Gateway that acts as **SNMP manager** towards many devices (SNMP agents) and
  as **IEC 60870-5-104 controlled station** (server) towards SCADA masters.
- SNMP v1, v2c, v3 (USM); cyclic polling **and** traps/informs, combined on the
  same datapoint (poll = authoritative state, trap = fast state change).
- Multiple IEC 104 servers, each with multiple redundancy groups, via
  [erl60870](https://github.com/Hoernchen20/erl60870).
- Routing per server: any datapoint can be mapped to one or more servers.
- Configuration via REST API and a React web UI; username/password users.
- Live debugging through the web UI (WebSocket).
- Erlang/OTP 27+, rebar3, OTP-native libraries wherever practical.
- Test-first: every pure module gets its eunit/PropEr tests before the
  implementation; every process gets a common_test suite.

Reference sizing (author's installation): ~30 devices × 24 interfaces + a few
device-level metrics (temperature, …), 30 s poll interval → roughly
3 000 points, ~100 values/s. This is light load; design for 10× headroom, not
for extreme scale.

Out of scope for v1: control direction (IEC commands → SNMP SET), value
history, clustering / multi-node.

## 2. Technology choices

| Concern | Choice | OTP-native |
|---|---|---|
| SNMP manager, v1/v2c/v3, traps, informs | `snmp` app — `snmpm`, agents and USM users registered at runtime | yes |
| MIB compilation (phase 2) | `snmpc` | yes |
| IEC 60870-5-104 server | `erl60870` (`iec60870` app) | — (own lib) |
| Config + user storage | Mnesia, `disc_copies`, single node | yes |
| JSON | OTP 27 `json` | yes |
| Password hashing | `crypto:pbkdf2_hmac/5`, SHA-256, per-user salt | yes |
| Debug event fan-out | `pg` | yes |
| Logging / counters | `logger`, `counters` | yes |
| HTTP, REST, WebSocket | **Cowboy** (inets `httpd` has no WebSocket); shares `ranch` 2.x with erl60870 | no |
| Frontend | React + TypeScript + Vite, TanStack Query; built into `apps/s2i_web/priv` | — |
| Tests | eunit, common_test, PropEr; `snmpa` as simulated agent; `gun` (test only) for WebSocket | mostly |

### Why Mnesia over PostgreSQL

Configuration is small (thousands of rows), changes rarely, and must be
available whenever the gateway runs. Mnesia ships with OTP, needs no external
service, offers transactions and change subscriptions (`mnesia:subscribe/1`).
PostgreSQL would pay off only for a centrally shared config across many
gateways or for storing value history — neither is a v1 goal. All storage
access goes through `s2i_config` so the backend remains replaceable.

## 3. Application layout (rebar3 umbrella)

```
apps/
  s2i_core/   config schema, validation, Mnesia store, profile expansion,
              route compiler, value transforms, trap matching, reconcile diff
  s2i_snmp/   snmpm user, device subtrees, pollers, trap dispatch
  s2i_iec/    reconciler over iec60870 servers, quality / comm-status points
  s2i_web/    cowboy: REST, auth, sessions, WebSocket, static React build
frontend/     React source (not part of the release; built into s2i_web/priv)
```

Rule of thumb: everything that can be a pure function lives in `s2i_core` and
is written test-first with eunit/PropEr. Processes stay thin.

## 4. Supervision tree

```
s2i_sup                                 rest_for_one
├── s2i_config          gen_server: Mnesia schema owner, staged/active config,
│                       validate + activate, emits {config_activated, Vsn}
├── s2i_routes          ETS owner: compiled routing table, swapped atomically
├── s2i_iec_sup         one_for_one
│   └── s2i_iec_mgr     reconciler: desired servers ↔ running iec60870 servers
├── s2i_snmp_sup        rest_for_one
│   ├── s2i_snmpm_user  snmpm user callback; traps / informs / reports →
│   │                   owning s2i_device (lookup by IP, not {IP, Port})
│   └── s2i_devices_sup DynamicSupervisor
│       └── s2i_device_sup          one per device, one_for_all
│           ├── s2i_device          gen_statem: agent/USM registration,
│           │                       health (up | degraded | down), trap intake
│           └── s2i_poller × N      one per poll group, drift-free schedule
├── s2i_debug           ring buffers (trap log, SNMP trace, events), pg topics
└── s2i_web_sup         cowboy listener(s), session table
```

- **One subtree per device**: a hanging or crashing device is isolated; a
  config change restarts only affected devices.
- **Reconciler pattern** on both sides: `s2i_reconcile:diff(Desired, Running)
  -> [start | stop | restart]` is pure and tested first; managers only execute
  the actions.
- `rest_for_one` at the root: if `s2i_config` or `s2i_routes` restarts, all
  consumers restart against a consistent config.

## 5. Configuration model

```
Profile ─< DatapointTemplate ─< MappingTemplate
   │            (OID template)        (type, transform, IOA offset)
   │
Device (profile, ioa_base, instances, overrides)
   │  expanded at activation
   ▼
Datapoint ─< Mapping >─ IecServer ─< RedundancyGroup
```

### 5.1 Entities

**IecServer** — `name`, transport (`tcp`/`tls` + port/certs), `common_addresses`,
`params` (k, w, t1–t3, field widths), `redundancy` (mode + groups with IP
matches), `background_scan` interval (optional).

**Device** — `name`, `host`, `port`, SNMP `version`, credentials (community or
USM user/auth/priv + engine id), `timeout`, `retries`, `max_varbinds`,
`profile`, `ioa_base`, `instances`, per-device overrides, `comm_status`
mapping (optional single point "device reachable").

**Profile** — reusable description of a device type:
- `poll_groups`: e.g. `#{status => 30000, counters => 60000}`
- `datapoint_templates`: `name` template, `oid` template, `poll_group`,
  `per_instance :: boolean()`
- `mapping_templates`: per datapoint template, a list of
  `#{server, coa, ioa_offset, type, transform, deadband}`
- `trap_rules`: see 5.3
- `ioa_stride`: IOA distance between instances

**Instances** — the per-device list of what an instance-scoped template is
expanded for. `slot` drives the IOA (stable, chosen by the engineer); the
SNMP table index substituted into the OID (`1.3.6.1.2.1.2.2.1.8.{index}`) is
given either statically or as a key that is resolved at runtime (§5.3):

```erlang
[#{slot => 1, index => 10101},                 %% static index
 #{slot => 3, key => {if_name, "Gi1/0/3"}}]    %% resolved by name (default for interfaces)
```

The profile declares how keys resolve, generically as "find the row in table
column X whose value equals K":

```erlang
resolvers => #{if_name  => #{column => "1.3.6.1.2.1.31.1.1.1.1"},   %% IF-MIB ifName
               if_descr => #{column => "1.3.6.1.2.1.2.2.1.2"}}      %% ifDescr fallback
```

The same mechanism covers other tables whose indexes are not stable, e.g.
ENTITY-SENSOR-MIB temperature sensors resolved by `entPhysicalName`.

### 5.2 Expansion and IOA assignment

```
IOA = device.ioa_base + instance.slot * profile.ioa_stride + template.ioa_offset
      (device-level templates: device.ioa_base + template.ioa_offset)
```

Example: `ioa_base = 10000`, `ioa_stride = 10`; interface slot 3, operStatus
offset 1 → IOA 10031. Temperature (device-level, offset 0) → 10000.

`s2i_profile:expand(Device, Profile) -> {ok, [Datapoint], [Mapping]}` is pure.
Per-device overrides can disable a datapoint or change a single mapping.
Datapoint names are stable and human-readable: `core-sw1/if3/operStatus`,
`core-sw1/temperature`.

### 5.3 Instance resolution (unstable table indexes)

Numeric OIDs do not avoid the ifIndex problem: the index *is* the last part of
the OID. If a device renumbers its interfaces, a static OID silently reads a
different port (or nothing), so **wrong data would be sent under a valid IOA**.
Therefore:

- `s2i_device` keeps a resolved map `Key → Index` (and the reverse
  `Index → Slot`, needed to route traps such as linkDown by their ifIndex).
- Resolution (a walk of the resolver column) runs on device start, on
  reconnect after `down`, and on **reboot detection**: every poll group of a
  device includes `sysUpTime.0`; a value lower than the previous one means the
  agent restarted. The same signal resets `rate`/`counter` transforms
  (counter discontinuity).
- If the map changes, the device's routes are rebuilt (only for that device).
- Key not found → datapoints of that instance are published `invalid`, and a
  warning goes to the log and the debug UI. Never fall back to a guessed index.
- Static `index` remains available for devices with guaranteed persistence
  (e.g. ifIndex persistence enabled) or tables without a usable name column.

`s2i_resolve:build(ResolverColumns, WalkResult) -> #{Key => Index}` and the
"did it change" comparison are pure and tested first.

### 5.4 Datapoint sources: poll + trap

A datapoint has an optional `poll_group` **and** may be updated by traps.

Trap handling, in this order:
1. **Varbind match (default, zero config).** For every varbind in a trap from
   device D, if its OID equals the OID of one of D's datapoints, apply the
   value. RFC 2863 `linkDown`/`linkUp` carry `ifAdminStatus.<i>` and
   `ifOperStatus.<i>`, so standard link traps work without explicit rules.
2. **Explicit trap rules** (from the profile) for traps that do not carry the
   value (instance taken from a varbind is mapped back to a slot via the
   reverse resolver map): `match` on trap OID (v1 enterprise/generic/specific normalised to the
   SNMPv2 `snmpTrapOID` form) + optional varbind conditions → `set` a constant
   or `take` a value from a named varbind, with optional `auto_reset_after`.
3. Unmatched traps go only to the debug trap log.

Optional per rule: `confirm_get_after` (ms) — schedule an immediate GET of the
affected datapoints to confirm the trap.

**Ordering rule (poll vs trap race).** Each datapoint records
`last_trap_at` (monotonic). A poll response is applied to a datapoint only if
its request was *sent* after `last_trap_at`; otherwise that value is discarded
for this cycle. This prevents a poll sampled before a link-down from
overwriting the trap. Lost traps (UDP) are corrected by the next poll.
Devices that support informs should use them (acknowledged).

### 5.5 Mapping and transforms

A mapping = datapoint → `(server, coa, ioa, type, transform, deadband)`. The
transform belongs to the mapping (two servers may want different types).

| Transform | Input | Output types |
|---|---|---|
| `linear` (scale, offset) | Integer/Gauge/Counter | M_ME_NA/NB/NC (+TD/TE/TF) |
| `enum` (value → state map) | Integer | M_SP, M_DP |
| `bit` (mask) | Integer / OCTET STRING | M_SP |
| `threshold` (op, limit) | numeric | M_SP |
| `counter` (wrap 32/64) | Counter32/64 | M_IT_NA/TB |
| `rate` (Δ/Δt × factor, wrap aware) | Counter32/64 | M_ME_NC/TF |

Example: ifOperStatus `enum #{1 => true, 2 => false, '_' => {false, [invalid]}}`
→ `m_sp_tb_1`.

`s2i_transform:apply(Transform, SnmpValue, PrevState) -> {ok, IecSpec, State}
| skip` is pure and property-tested (wrap handling, scaling bounds, overflow →
`overflow` quality).

Deadband (absolute / percent) is applied in the gateway before
`iec60870_server:update/2`; erl60870's own change gate still suppresses
identical values.

### 5.6 Validation (on activate)

- `(server, coa, ioa)` unique across the whole active config
- `coa` ∈ server `common_addresses`; IOA within `ioa_size`
- transform output compatible with IEC type
- OIDs syntactically valid; poll groups referenced exist
- referenced profile / server exists; device names unique

Validation is a pure function returning *all* errors (for the UI), not the
first.

### 5.7 Staged vs active config

Edits go to a **staged** config. `POST /api/v1/config/activate` validates,
stores a new **active version** (with author, timestamp, diff summary in an
audit table), and broadcasts `{config_activated, Vsn}`. Reconcilers react.
The UI warns when an activation restarts an IEC server (drops connections).
Full config export/import as JSON for backup and version control.

### 5.8 Mnesia tables (initial)

`s2i_iec_server`, `s2i_device`, `s2i_profile`, `s2i_config_meta`
(active version, staged flag), `s2i_audit`, `s2i_user`. Each record carries a
`schema_vsn` field to make later `mnesia:transform_table/3` migrations explicit.
Expanded datapoints/mappings are **not** stored; they are derived on
activation and held in `s2i_routes`.

## 6. Runtime data flow

```
s2i_poller ── GET (chunked by max_varbinds) ──► snmpm ──► device
    │  varbinds, request sent_at, received_at
    ▼
s2i_routes  ETS {DeviceId, Oid} → [Route]        (lookup in caller, no hub process)
    ▼
ordering check (sent_at > last_trap_at) → transform → deadband
    ▼
group by server → iec60870_server:update(Server, Writes)   (cast, batched)
    └─► live-value ETS + pg debug topic (only if subscribed)

s2i_snmpm_user ── trap/inform ──► s2i_device (by source IP)
    ▼
varbind match / trap rules → same path as above (sets last_trap_at)
```

- Timestamps: CP56Time2a from `received_at` (poll) or trap reception time;
  mappings default to the time-tagged types (`*_TB_1`, `*_TF_1`).
- One request in flight per poller; an overrun (previous cycle still running)
  is counted and the tick skipped.
- `snmpm` async API (`async_get2/4`), results via `handle_pdu/4` callback
  routed back to the requesting poller.

### 6.1 Quality and communication status

- Device health: N consecutive poll failures (configurable, default 3) →
  `down`. On `down`, every mapping of that device is re-sent with last value
  and quality `[invalid]` (or `[not_topical]`, configurable). Recovery on the
  next successful poll.
- Optional per-device comm-status single point.
- Before the first good value, a point is published as `invalid`, so general
  interrogation never reports a fabricated state.
- erl60870 server down/restart → `s2i_iec_mgr` re-seeds all current values
  from the live-value ETS after start.

## 7. IEC 104 side

- `s2i_iec_mgr` starts one `iec60870` server per configured `IecServer`
  under the library's own `iec60870_instances_sup` (`iec60870:start_server/2`).
- Redundancy groups map 1:1 to erl60870 `redundancy => #{mode => multiple,
  groups => [...]}`.
- Callback module `s2i_iec_callback` (`iec60870_server` behaviour): rejects
  all commands in v1, accepts clock sync without setting the system clock,
  reports connection events to `s2i_debug`.
- Optional background scan: `s2i_iec_mgr` timer re-sends all values with
  `cot => background`.
- On config change: points added → `update/2`; points removed →
  `remove/2` (**upstream change, see §11**); server-level change (port, COA,
  redundancy, TLS) → server restart.

## 8. SNMP side

- `snmpm` started by `s2i_snmp_sup` with a generated minimal `manager.conf`
  (engine id, port, address) in the release's data dir; agents and USM users
  are registered at runtime from config (`snmpm:register_agent/3`,
  `register_usm_user/3`).
- Trap port 162 requires `CAP_NET_BIND_SERVICE` or a port redirect;
  configurable.
- Traps arriving from an unregistered `{IP, Port}` (common: different source
  port) land in `handle_agent/5`; `s2i_snmpm_user` resolves the device by IP.
- SNMPv3 traps: the device's engine id must be configured (it is the
  authoritative engine for traps); informs use the gateway's engine id.
- **Spike first (phase 4a):** confirm these three snmpm behaviours with
  `snmpa` in common_test before building on them.

## 9. Web: REST, auth, WebSocket

### 9.1 REST (`/api/v1`, JSON)

`servers`, `devices`, `profiles`, `users` (CRUD), `config/staged`,
`config/validate`, `config/activate`, `config/export`, `config/import`,
`config/audit`, `status` (devices, servers, groups), `tools/snmp/get`,
`tools/snmp/walk`. An OpenAPI document is maintained alongside and used to
generate the TypeScript client types.

### 9.2 Auth

- Users in Mnesia: `username`, `pbkdf2-sha256` hash + salt + iterations,
  `role :: admin | viewer`.
- `POST /api/v1/login` → random 256-bit session token in an `HttpOnly`,
  `Secure`, `SameSite=Strict` cookie; sessions in ETS with idle + absolute
  expiry. `viewer` may read and use debug views, `admin` may change config.
- CSRF: SameSite cookie + required custom header on mutating requests.
- First start: bootstrap admin from release config / env, forced password change.
- HTTPS via cowboy TLS listener (OTP `ssl`).

### 9.3 WebSocket debugging (`/ws`)

Client subscribes to topics; each topic is a `pg` group, so producers pay
nothing when nobody listens.

| Topic | Content |
|---|---|
| `values:device:<name>` / `values:server:<name>` | live value updates with quality |
| `snmp:trace:<device>` | request/response PDUs (opt-in, rate-limited) |
| `traps` | all received traps, flagged matched / unmatched |
| `iec:<server>` | connections, active member per group, buffer fill |
| `log` | `logger` handler stream (level filter) |

Ring buffers in `s2i_debug` give a new subscriber the recent history.

## 10. Testing strategy

| Layer | Tests |
|---|---|
| `s2i_transform`, `s2i_profile` (expand), `s2i_validate`, `s2i_route` (compile), `s2i_trap_match`, `s2i_reconcile` (diff), ordering rule | eunit + PropEr, written before the code |
| `s2i_config` + Mnesia | common_test, fresh schema per suite |
| SNMP | common_test with OTP `snmpa` as simulated agent (v1/v2c/v3, test MIB, traps sent from the suite) |
| IEC | common_test with a minimal test master (APCI + `iec60870_asdu` codec: STARTDT, GI, receive spontaneous) |
| End to end | `snmpa` → gateway → test master, incl. linkDown race and device-down quality |
| REST / WS | `httpc` + `gun` |
| Frontend | Vitest + React Testing Library |

`rebar3 check` alias: compile + eunit + xref + dialyzer (as in erl60870);
`rebar3 ct` separately; CI on OTP 27 and 28.

## 11. Upstream work in erl60870

- **Point removal:** `iec60870_server:remove(Server, [{Coa, Ioa}])`, new
  optional data-model callback `delete/3` (implemented in `iec60870_dm_ets`),
  so removed IOAs no longer answer interrogation.

## 12. Implementation phases

0. Umbrella skeleton, rebar3 aliases, CI, erl60870 dependency
1. Config schema, validation, Mnesia store, staged/active, audit
2. Profiles + expansion, instance resolution, transforms, route compiler (pure)
3. IEC side: reconciler, callback, quality seeding (+ upstream `remove/2`)
4. SNMP polling: 4a snmpm spike, 4b v1/v2c, 4c v3/USM, device health
5. Traps/informs: varbind match, trap rules, ordering rule, confirm-GET
6. REST API + auth
7. React UI + WebSocket debugging
8. MIB library (phase 2 feature, see §13)

## 13. MIBs (deferred)

Runtime works exclusively on numeric OIDs. A later MIB library adds upload →
`snmpc` compile → name table for OID↔name display, OID browser, enum labels
(assist building `enum` transforms) and trap names in the trap log. Compile
failures (common with vendor MIBs) are reported and never block numeric
configuration.

## 14. Decisions

| # | Question | Decision |
|---|---|---|
| 1 | Routing granularity | per IEC server; all redundancy groups of a server see the same points |
| 2 | Config storage | Mnesia (single node), access only via `s2i_config` |
| 3 | Naming / mapping | Device → Datapoint → Mapping; profiles with IOA base/stride/offset |
| 4 | OIDs vs MIBs | numeric OIDs at runtime; MIBs later, UI-assist only |
| 5 | Poll + trap | both on one datapoint; trap applied immediately, poll discarded if sent before last trap |
| 6 | HTTP server | Cowboy (WebSocket); everything else OTP-native |
| 7 | Frontend | React + TypeScript + Vite |
| 8 | Point removal | upstream in erl60870 |
| 9 | Device profiles | in v1 |
| 10 | Unstable table indexes | runtime instance resolution by name column (ifName default), re-resolved on start / reconnect / reboot |

## 15. Open points and planned extensions

- **Interface traffic / error metrics** (octet rates, errors, discards): not
  needed in v1, but the design keeps them cheap to add: `rate`/`counter`
  transforms with wrap handling and `sysUpTime`-based discontinuity reset,
  separate poll groups per profile (e.g. `counters => 60000`), and HC
  (64-bit) counters on v2c/v3. If the number of OIDs per device grows a lot,
  add GETBULK-based table polling as an alternative to chunked GET.
