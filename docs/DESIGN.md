# snmp2iec104 — Design

Status: **phases 0–7 implemented** (config, expansion, IEC side, SNMP
polling, traps/informs, REST API + auth, web UI + WebSocket debugging); the
MIB library follows (§12, §13). Scope of v1: monitoring direction
only, SNMP → IEC 60870-5-104.

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
  snmp2iec104/ application entry point; owns the root supervisor s2i_sup
  s2i_core/   config schema, validation, Mnesia store, profile expansion,
              route compiler, value transforms, trap matching, reconcile diff
  s2i_snmp/   snmpm user, device subtrees, pollers, trap dispatch
  s2i_iec/    reconciler over iec60870 servers, quality / comm-status points
  s2i_web/    cowboy: REST, auth, sessions, WebSocket, static React build
frontend/     React source (not part of the release; built into s2i_web/priv)
```

`snmp2iec104` is the only app with an application callback. The other four
are library applications that export their subtree supervisors
(`s2i_iec_sup:child_spec/0`, …), so the whole gateway runs under one
`rest_for_one` root as shown in §4, while code dependencies stay one-way
(`s2i_core` depends on none of the others).

Rule of thumb: everything that can be a pure function lives in `s2i_core` and
is written test-first with eunit/PropEr. Processes stay thin.

## 4. Supervision tree

```
s2i_sup                                 rest_for_one
├── s2i_config          gen_server: Mnesia schema owner, staged/active config,
│                       validate + activate, emits {config_activated, Vsn}
├── s2i_routes          ETS owner: compiled routing table, swapped atomically
├── s2i_iec_sup         rest_for_one
│   ├── s2i_live        ETS owner: every configured point + current value
│   └── s2i_iec_mgr     reconciler: desired servers ↔ running iec60870 servers
├── s2i_snmp_sup        rest_for_one
│   ├── snmpm           OTP SNMP manager (snmpm_supervisor, via s2i_snmpm);
│   │                   default user s2i_snmpm_user (callback module)
│   ├── s2i_devices_sup one_for_one, one child per device; owns the
│   │   │               s2i_trap_sources table (source IP → device)
│   │   └── s2i_device  gen_server: agent/USM registration, instance
│   │                   resolution, poll groups (drift-free schedule),
│   │                   health (up | degraded | down), traps/informs
│   └── s2i_snmp_mgr    reconciler: desired devices ↔ running s2i_device
├── s2i_debug_sup       one_for_all: pg scope s2i_debug_pg + s2i_debug
│                       (ring buffers of the buffered topics, log handler)
└── s2i_web_sup         cowboy listener(s), session table
```

- **One process per device**: a hanging or crashing device is isolated; a
  config change restarts only affected devices. Each device registers its
  own snmpm user (user data = its pid), so responses, errors and reports of
  its requests arrive at that process directly; the poll groups are timers
  inside it, not separate processes (no routing of responses between
  processes, one consistent state per device).
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

**Device** — `name`, `host`, `port`, `snmp` (version + community, or USM
user/sec level/auth/priv + engine id), `timeout`, `retries`, `max_varbinds`,
`down_after`, `enabled`, `profile`, `ioa_base`, `instances`, `targets`,
`comm_status` (optional single point "device reachable"), `overrides`
(§5.2).

**Profile** — reusable description of a device type:
- `poll_groups`: e.g. `#{status => 30000, counters => 60000}`
- `resolvers`: see below
- `datapoints`: `name` template, `oid` template, `scope` (`device` |
  `instance`), optional `poll_group`, and `mappings`: a list of
  `#{target, ioa_offset, type, transform, deadband}`
- `ioa_stride`: IOA distance between instances
- `trap_rules`: see 5.4

**Targets (routing).** A profile never names an IEC server: its mappings
carry a **target label** (default `"default"`). Each device binds labels to
servers and common addresses, so devices sharing a profile can feed different
servers, and one label can fan out to several:

```erlang
%% sw-a, sw-b                                %% sw-c
targets => #{<<"default">> =>                targets => #{<<"default">> =>
    [#{server => <<"scada1">>, coa => 1}]}       [#{server => <<"scada2">>, coa => 1}]}
```

A label the profile uses but the device does not bind produces no mappings
for that device (e.g. leave out `"counters"`); binding a label the profile
does not use is an error (typo protection).

**Instances** — the per-device list of what an instance-scoped template is
expanded for. `slot` drives the IOA (stable, chosen by the engineer); the
SNMP table index substituted into the OID (`1.3.6.1.2.1.2.2.1.8.{index}`) is
given either statically or as a key that is resolved at runtime (§5.3):

```erlang
[#{slot => 1, index => 10101},                                        %% static index
 #{slot => 3, key => #{resolver => <<"if_name">>, value => <<"Gi1/0/3">>}}]  %% resolved by name
```

The profile declares how keys resolve, generically as "find the row in table
column X whose value equals K":

```erlang
resolvers => #{<<"if_name">>  => #{column => <<"1.3.6.1.2.1.31.1.1.1.1">>},  %% IF-MIB ifName
               <<"if_descr">> => #{column => <<"1.3.6.1.2.1.2.2.1.2">>}}     %% ifDescr
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

`s2i_expand:device(Device, Profile) -> {ok, Expansion}` is pure; each datapoint
carries its concrete OID (static index substituted) or `{key, Prefix,
{Resolver, Value}}` for runtime resolution, plus one mapping per target
binding. Datapoint ids are stable and human-readable:
`core-sw1/if3/operStatus`, `core-sw1/temperature`.

**Overrides** (per device) address a datapoint template by name, optionally
limited to some slots:

```erlang
overrides => [#{datapoint => <<"if{slot}/inOctets">>, enabled => false},
              #{datapoint => <<"if{slot}/operStatus">>, slots => [24],
                mappings => [#{index => 0, type => m_dp_tb_1,
                               transform => #{kind => enum, map => #{...}}}]}]
```

A mapping patch (by position in the template) may disable the mapping or
replace `type`, `transform`, `deadband`; the merged mapping is checked like a
profile mapping. Unknown datapoints, slots or mapping indexes, `slots` on a
device-scope datapoint and two overrides covering the same datapoint/slot are
errors. Disabled devices keep their IEC addresses (they still count for
collisions).

### 5.3 Instance resolution (unstable table indexes)

Numeric OIDs do not avoid the ifIndex problem: the index *is* the last part of
the OID. If a device renumbers its interfaces, a static OID silently reads a
different port (or nothing), so **wrong data would be sent under a valid IOA**.
Therefore:

- `s2i_device` keeps a resolved map `Key → Index`; the compiled routes map
  `{Template, Index}` back to the datapoint, so trap rules find the datapoint
  of the ifIndex a linkDown carries (per template: different tables of a
  device have different index spaces).
- Resolution (a walk of the resolver column) runs on device start, on
  reconnect after `down`, and on **reboot detection**: every poll group of a
  device includes `sysUpTime.0`; a value lower than the previous one means the
  agent restarted. The same signal resets `rate`/`counter` transforms
  (counter discontinuity).
- If the map changes, the device's routes are rebuilt (only for that
  device); newly resolved datapoints are read at once with a one-off GET
  instead of waiting for the next poll of their group.
- Key not found → datapoints of that instance are published `invalid`, and a
  warning goes to the log and the debug UI. Never fall back to a guessed index.
- Static `index` remains available for devices with guaranteed persistence
  (e.g. ifIndex persistence enabled) or tables without a usable name column.

`s2i_resolve:build(Column, Rows) -> {#{Value => Index}, Ambiguous}` (a value
in several rows is ambiguous and left unresolved), `keys/1` (what a device
needs) and `changed/3` (which of the device's keys moved) are pure.

### 5.4 Datapoint sources: poll + trap

A datapoint has an optional `poll_group` **and** may be updated by traps.

Trap handling, in this order:
1. **Varbind match (default, zero config).** For every varbind in a trap from
   device D, if its OID equals the OID of one of D's datapoints, apply the
   value. RFC 2863 `linkDown`/`linkUp` carry `ifAdminStatus.<i>` and
   `ifOperStatus.<i>`, so standard link traps work without explicit rules.
2. **Explicit trap rules** (from the profile) for traps that do not carry the
   value, applied after the varbind match (so a rule wins on the same
   datapoint). Rules match on the trap OID (SNMPv1 enterprise/generic/specific
   normalised to the SNMPv2 `snmpTrapOID` form, RFC 3584 §3.1) and optional
   varbind conditions, then `set` a constant or `take` the value of a varbind.
   The value goes through the datapoint's transforms like a polled value.
   For an instance-scope datapoint the rule says where the table index is:
   the last OID component of a varbind (`suffix`, e.g. `ifIndex.<i>`) or its
   value (`value`). An index that is not configured or not resolved matches
   nothing; there is no guessing.
3. Unmatched traps are counted per device (`traps`, `unmatched` in the
   device status) and logged at debug level; the trap log of the debug UI
   follows in phase 7.

```erlang
trap_rules =>
  [#{name => <<"link-down">>,                          %% unique per profile
     trap_oid => <<"1.3.6.1.6.3.1.1.5.3">>,            %% linkDown (v1: generic 2)
     conditions => [#{oid => <<"1.3.6.1.2.1.2.2.1.7">>, op => eq, value => 1}],  %% optional
     datapoint => <<"if{slot}/operStatus">>,           %% template name
     instance => #{oid => <<"1.3.6.1.2.1.2.2.1.1">>, from => value},  %% instance scope only
     set => 2},                                        %% or take => VarbindOid
   #{name => <<"psu-alarm">>, trap_oid => <<"1.3.6.1.4.1.9.0.7">>,
     datapoint => <<"psu_alarm">>, set => 1,
     auto_reset => #{delay => 60000, value => 0},      %% optional
     confirm_get_after => 500}]                        %% optional
```

A condition matches the first varbind whose OID is the condition's OID or
below it (table column); integer constants equal any integer syntax, strings
equal octet strings (or an OID in dotted form). A missing varbind fails the
condition. `auto_reset` is one timer per datapoint, restarted by every
matching trap. `confirm_get_after` (ms) schedules a one-off GET of the
datapoint to confirm the trap; failures only log. Trap-only datapoints (no
`poll_group`) are invalid until their first trap, and again after the device
was `down`.

**Ordering rule (poll vs trap race).** Each datapoint records
`last_trap_at` (monotonic). A poll response is applied to a datapoint only if
its request was *sent* after `last_trap_at`; otherwise that value is discarded
for this cycle. This prevents a poll sampled before a link-down from
overwriting the trap. Lost traps (UDP) are corrected by the next poll.
Devices that support informs should use them (acknowledged by snmpm before
the gateway sees them; an SNMPv3 inform may arrive twice, see §8, which is
harmless because values are only sent when they change).

### 5.5 Mapping and transforms

An expanded mapping = datapoint → `(server, coa, ioa, type, transform,
deadband)`, one per target binding. The transform belongs to the mapping (two
targets may want different types).

| Transform | Input | Output types |
|---|---|---|
| `linear` (scale, offset) | Integer/Gauge/Counter | M_ME_NA/NB/NC (+TD/TE/TF) |
| `enum` (value → state map, optional default) | Integer | M_SP, M_DP, M_ST |
| `bit` (mask) | Integer / OCTET STRING | M_SP |
| `threshold` (op, limit) | numeric | M_SP |
| `counter` (wrap 32/64) | Counter32/64 | M_IT_NA/TB |
| `rate` (Δ/Δt × factor, wrap aware) | Counter32/64 | M_ME_NC/TF |

Example: ifOperStatus `#{kind => enum, map => #{<<"1">> => true, <<"2">> => false}}`
→ `m_sp_tb_1`; a value without entry and without `default` is published with
quality `invalid`. Transform parameters and the type compatibility above are
checked by the schema (phase 1); applying them is `s2i_transform` (phase 2).

`s2i_transform` is pure and property-tested, in three steps:
`convert(Transform, SnmpValue, NowMs, State)` → engineering value (or
`skip` / `{invalid, Reason}`; `rate` keeps the last sample, wrap-aware for
Counter32/64), `deadband(Deadband, New, LastSent)`, and `encode(Type, Eng)` →
erl60870 point fields. Encoding details: normalized values as signed 16-bit
fractions, scaled values rounded, floats as float32; out-of-range values are
clamped with quality `overflow`. Integrated totals are reported modulo 2^31
(BCR is signed 32-bit). `bit` on an OCTET STRING follows SNMP BITS order
(bit 0 = MSB of the first octet).

Deadband (absolute / percent) is applied in the gateway before
`iec60870_server:update/2`; erl60870's own change gate still suppresses
identical values.

### 5.6 Validation

Three levels, all pure and returning *all* errors (for the UI), each as
`#{path => [devices, <<"sw-a">>, targets, <<"default">>, 0, coa], error => unknown_coa}`:

1. **Entity schema** (`s2i_schema`, on every write): types, ranges, formats
   (names, hosts, IPs, CIDRs, OIDs, engine ids), SNMPv3 fields per security
   level, `w ≤ ⅔k`, `t2 < t1`, placeholders (`{index}` in instance OIDs,
   `{slot}` in instance names), poll-group references inside a profile,
   instance offsets `< ioa_stride`, transform/type compatibility, deadband only
   on measured values, duplicates (COAs, slots, indexes, group names,
   datapoint names, offsets per scope + label).
2. **Configuration** (`s2i_validate:config/1`, on activate): profile, server,
   COA, resolver and target-label references; comm-status IOA within the
   server's `ioa_size`; listener port conflicts (same port on the same or a
   wildcard address).
3. **Expansion** (`s2i_expand:config/1`, part of `s2i_validate:config/1`):
   overrides, `(server, coa, ioa)` unique across all expanded mappings and
   comm-status points (`ioa_collision`, reported on the later device by name
   with `detail => #{server, coa, ioa, with => EarlierPath}`); IOAs within
   `1..2^(8·ioa_size)-1` (`out_of_range`).

The canonical form produced by the schema is JSON-safe: atom keys and enums,
binary strings, absent optionals. JSON input (binary keys and values, `null`)
is accepted directly without creating atoms.

### 5.7 Staged vs active config

Edits go to a **staged** config (`s2i_config:put/3`, `delete/3`; whole-config
`import/2`, `revert/1`, `restore/2`). `activate/2` validates, stores a new
immutable **version** (author, timestamp, comment) — the newest version is
the **active** config — and sends `{s2i_config, {activated, Vsn}}` to
subscribers. Reconcilers react. Rollback = `restore(Vsn)` + `activate`.
Every change is recorded in an audit log with its actor.
The UI warns when an activation restarts an IEC server (drops connections).
Full config export/import as JSON for backup and version control.

### 5.7a Stored secrets

SNMP communities and USM passwords are encrypted before they reach Mnesia
(`s2i_secret`): AES-256-GCM, random IV per value, stored as the text envelope
`enc:v1:<key id>:<base64(iv|tag|ciphertext)>`. Staged config, versions and
exports only contain envelopes; plaintext exists only where the SNMP manager
needs it. Re-saving an unchanged plaintext keeps the old ciphertext (no
spurious change).

- **Key file, not environment variable**: env vars leak through
  `/proc/<pid>/environ`, child processes and crash/diagnostic dumps; a file
  can be locked down with permissions and kept out of the data backup.
  `s2i_core.secret_key_file` (default `etc/secret.key`) holds the base64
  32-byte key (`openssl rand -base64 32`). Startup is refused if the file is
  accessible by group/others; a missing file is generated with mode 0600 and
  a warning to back it up.
- The key id in the envelope detects ciphertext from another key: put/import
  of such values is rejected (`wrong_key`), and activation is blocked if the
  key file was replaced. Exports are therefore only importable into an
  installation with the same key. Key rotation (re-encrypt with a new key id)
  is a later admin action.
- The REST API never returns secrets (write-only fields, §9).

### 5.8 Mnesia tables (initial)

| Table | Type | Content |
|---|---|---|
| `s2i_iec_server`, `s2i_profile`, `s2i_device` | set | staged entities `{Tab, Name, SchemaVsn, Map}` |
| `s2i_config_version` | ordered_set | `{Tab, Vsn, Meta, Config}`, immutable snapshots |
| `s2i_audit` | ordered_set | `{Tab, Id, Entry}`, newest 10 000 kept |
| `s2i_user` | set | web users `{Tab, Name, SchemaVsn, Map}` (§9.2); not part of versions/exports |

`SchemaVsn` makes later `mnesia:transform_table/3` migrations explicit; a
table whose attributes differ from the code's layout fails startup loudly.
Mnesia runs with a disc schema in `data/mnesia` (release-relative, `sys.config`).
Whole-config snapshots per version keep diffs and rollback trivial; at the
reference size a snapshot is a few hundred kB.
Expanded datapoints/mappings are **not** stored; they are derived on
activation and held in `s2i_routes`.

## 6. Runtime data flow

```
s2i_device ── GET (chunked by max_varbinds) ──► snmpm ──► device
    │  varbinds, request sent_at, received_at (s2i_poll: chunks, schedule,
    │  reboot detection, varbind → value)
    ▼
s2i_routes  ETS {DeviceId, Oid} → [Route]        (lookup in caller, no hub process)
            compiled by s2i_routes:device(Expansion, Resolved): routes, poll
            groups (+ sysUpTime.0), unresolved datapoints, index → slot
    ▼
ordering check (sent_at > last_trap_at) → s2i_sample (pure):
transform → only changes / deadband → encode
    ▼
group by server → s2i_iec:publish/2 | s2i_iec:invalidate/2
    └─► s2i_live + iec60870_server:update (cast, batched)
        + pg debug topic (only if subscribed, phase 7)

s2i_snmpm_user ── trap/inform ──► s2i_device (registered address: own
    │                                 snmpm user; other port: s2i_trap_sources)
    ▼
s2i_trap_match (pure): normalise, varbind match, trap rules
    ▼
same path as above (sets last_trap_at); auto-reset timers, confirm GETs
```

- Timestamps: CP56Time2a from `received_at` (poll) or trap reception time;
  mappings default to the time-tagged types (`*_TB_1`, `*_TF_1`).
- One cycle in flight per poll group; an overrun (previous cycle still
  running, or slots missed) is counted and the tick skipped.
- `snmpm` async API (`async_get2/4`, walks with `async_get_bulk2/6` or
  `async_get_next2/4` on v1). snmpm neither retries nor reports the timeout
  of an async request, so `s2i_device` runs a timer per request and resends
  up to `retries` times. SNMPv1 `noSuchName` fails the whole PDU: the missing
  OID is marked and the rest asked again in the same cycle.
- A value is sent only when it changed (deadband against the last *sent*
  value for measurements); after `invalid` or `down`, the next good value is
  sent even if unchanged.

### 6.1 Quality and communication status

- Device health: N consecutive failed poll cycles (`down_after`, default 3)
  → `down`. On `down`, every mapping of that device is re-sent with last value
  and quality `[invalid]` (`s2i_iec:invalidate/2`; `not_topical` as an
  option is left for later). Recovery on the next successful cycle, which
  also resolves the instances again. Between 1 and N-1 failures the device
  is `degraded` and its values stay as they are.
- Optional per-device comm-status single point: `true` when up, `false` when
  down (good quality in both cases), invalid before the first contact.
- Before the first good value, a point is published as `invalid`, so general
  interrogation never reports a fabricated state.
- erl60870 server down/restart → its data model (`s2i_iec_dm`) re-seeds all
  current values from the live-value table (`s2i_live`) on init, whoever
  restarts it (erl60870's supervisor or `s2i_iec_mgr`).

## 7. IEC 104 side

- `s2i_iec_mgr` starts one `iec60870` server per configured `IecServer`
  under the library's own `iec60870_instances_sup` (`iec60870:start_server/2`,
  name `{s2i, Name}`), translated by `s2i_iec_config:server/1` (pure). On start
  it stops leftover `{s2i, _}` servers, so its view is always accurate. A
  server that fails to start (port still in use) is retried every 2 s.
- `s2i_live` holds `{{Server, Coa, Ioa}, #{type, source}, Spec}` for every
  configured point; new points get an invalid seed. `s2i_iec:publish/2`
  stores a value there first (dropping values for points that are not
  configured with that type), then calls `iec60870_server:update/2`.
- Data model `s2i_iec_dm` = `iec60870_dm_ets` seeded from `s2i_live` on init.
- Redundancy groups map 1:1 to erl60870 `redundancy => #{mode => multiple,
  groups => [...]}`.
- Callback module `s2i_iec_callback` (`iec60870_server` behaviour): only
  `connection_event/2` (logged; debug topics in phase 7). Without
  `select/execute`, erl60870 rejects all commands; without `clock_sync/3`
  it confirms clock sync without touching the system clock.
- Optional background scan: `s2i_iec_mgr` timer re-sends all values with
  `cot => background`.
- On config change (`s2i_reconcile:servers/2`, `points/2`, pure): all stops
  first, then `s2i_live` is updated, then starts; on servers that keep
  running, points removed → `remove/2` (**upstream, see §11**), points added
  → `update/2` with the invalid seed (spontaneous). A point whose type or
  source changed is removed and added again. Server-level change (anything in
  `s2i_iec_config:server/1`: transport, COAs, params, redundancy) → restart;
  `background_scan` and `description` do not restart.

## 8. SNMP side

- `snmpm` started by `s2i_snmp_sup` (`s2i_snmpm`) with a generated minimal
  `manager.conf` (engine id, port, address) in the release's data dir; agents
  and USM users are registered at runtime from config
  (`snmpm:register_agent/3`, `register_usm_user/3`, keys localized per
  engine id by `s2i_snmp_conf`). The gateway's engine id is configurable
  (`s2i_snmp` `engine_id`) or generated once into `data/snmp/engine_id`.
- One UDP socket for requests and traps; port 162 requires
  `CAP_NET_BIND_SERVICE` or a port redirect; configurable. If the port cannot
  be bound, start-up fails with one clear log message.
- SNMPv3 without a configured `engine_id`: discovered by `s2i_snmp_discover`
  (RFC 3414 §4 probe from a separate socket); snmpm has no discovery.
- IPv4 only for now (snmpm transport `transportDomainUdpIpv4`).
- Traps arriving from an unregistered `{IP, Port}` (common: different source
  port) land in `handle_agent/5`; `s2i_snmpm_user` resolves the device by IP
  (`s2i_trap_sources`, filled by the devices when registered). If several
  devices share the IP, the trap is dropped with a warning.
- SNMPv3 traps: the device's engine id must be known (configured or
  discovered; it is the authoritative engine for traps). Informs use the
  gateway's engine id (`s2i_snmpm:engine_id/0`): every v3 device also
  registers its USM user under it. Devices sharing a user name must use the
  same passwords for informs (the last registration wins).
- **Spike (phase 4a), `s2i_snmpm_spike_SUITE` against `snmpa`:** confirmed
  the behaviours above, plus what the implementation relies on:
  - `snmpm:start_link/1` returns `ok`, not `{ok, Pid}`: the gateway
    supervises `snmpm_supervisor:start_link(normal, Opts)` directly.
  - `engine_id` is mandatory in `register_agent/3`, also for v1/v2c
    (placeholder).
  - `update_agent_info/4` on `taddress` leaves snmpm's address index stale
    (traps from the old address still match): an address change is
    unregister + register, i.e. a device restart.
  - Unanswered async requests are dropped silently (no `handle_error`).
  - v3: the first request to an agent (and the first after its reboot) gets
    a `usmStatsNotInTimeWindows` report via `handle_report/3`, without the
    request id, and snmpm does not resend; the next request works. The
    device resends its outstanding requests once on a report.
  - v3 traps need the USM user under the agent's engine id; informs under the
    gateway's engine id (the agent's first inform hits a time-window report,
    its retransmission is accepted, so duplicates are possible).
  - A v3 agent with an unknown engine id fails fast with
    `unknownSecurityName`.
  - `snmpm_conf` writes the engine id unescaped (`"~s"`), so `s2i_snmpm`
    writes `manager.conf` itself.

## 9. Web: REST, auth, WebSocket

### 9.1 REST (`/api/v1`, JSON)

`servers`, `devices`, `profiles`, `users` (CRUD), `config/staged`,
`config/validate`, `config/activate`, `config/export`, `config/import`,
`config/audit`, `status` (devices, servers, groups), `tools/snmp/get`,
`tools/snmp/walk`. An OpenAPI document is maintained alongside and used to
generate the TypeScript client types.

As implemented (phase 6):

- One cowboy handler (`s2i_web_api`) for `/api/v1/[...]`; the route table
  with the access level of every operation is pure data
  (`s2i_web_rest:routes/0`). Listeners are ranch children of `s2i_web_sup`
  (`s2i_web` env `http` / `https`; the default config binds HTTP to
  localhost only).
- Entities: `GET /{servers,devices,profiles}[/{name}]`, `PUT` = create or
  replace (name in the body optional, must match the path), `DELETE`. `PUT`
  runs the schema check (422 with the `s2i_schema` errors); references are
  checked by `POST config/validate` (always 200: `valid`, `errors`,
  `server_restarts` = servers the activation would restart, for the UI
  warning, `s2i_iec_config:restarts/2`) and `config/activate`.
- Versions: `config/active`, `config/versions[/{vsn}]`,
  `POST config/versions/{vsn}/restore`, `POST config/revert`;
  `config/export?source=staged|active`.
- Secrets (§5.7a): entities are returned as stored, so communities and USM
  passwords only appear as `enc:v1:` envelopes. That keeps them write-only
  without a separate "unchanged" marker: a GET body sent back with `PUT`
  keeps the secret; a plaintext value replaces it.
- Status: devices of the active configuration with `s2i_device:status/1`
  (health, counters, resolution), IEC servers with `running | start_failed`
  (`s2i_iec_mgr:status/0`), their point count and (phase 7) their
  redundancy groups (`s2i_iec:groups/1`: active connection yes/no, open
  connections, unacknowledged ASDUs). Values not known yet (`last_ok`
  before the first good poll, `error`) are `null`.
- SNMP tools go through a configured, running device (`s2i_device:get/2`,
  `walk/3`): the request uses its registration, so no credentials travel in
  API requests. GET is limited to `max_varbinds` OIDs, walk to `max`
  varbinds (default 1000, `truncated` flag); timeouts and retries are the
  device's, results do not count for health.
- `GET /api/v1/openapi.json` (public): OpenAPI 3.1; the entity schemas are
  generated from the `s2i_schema` specs (`json_schema/1`, with `x-order` =
  the field order of the spec, for the UI forms), and a test keeps the
  documented paths equal to the route table.
- Errors: `{"error": Code, "errors": [#{path, error, detail}]}`; 400 bad
  request / JSON, 401, 403 (`forbidden`, `csrf`, `password_change_required`),
  404, 405 (`allow` header), 409 (`no_changes`, `last_admin`), 413 (> 8 MB),
  422 (validation), 503 (device not running / registered), 504 (SNMP timeout).

### 9.2 Auth

- Users in Mnesia: `username`, `pbkdf2-sha256` hash + salt + iterations,
  `role :: admin | viewer`.
- `POST /api/v1/login` → random 256-bit session token in an `HttpOnly`,
  `Secure`, `SameSite=Strict` cookie; sessions in ETS with idle + absolute
  expiry. `viewer` may read and use debug views, `admin` may change config.
- CSRF: SameSite cookie + required custom header on mutating requests.
- First start: bootstrap admin from release config / env, forced password change.
- HTTPS via cowboy TLS listener (OTP `ssl`).

As implemented (phase 6):

- `s2i_password` (pure): PBKDF2-HMAC-SHA256, 16-byte salt, 32-byte hash,
  constant-time compare; `s2i_core` `password_iterations` (default 600 000,
  ≈ 0.5 s per login). Stored hashes with fewer iterations are renewed on
  the next login; unknown user names cost a dummy derivation (no user
  enumeration by timing). Passwords: 8–1024 bytes UTF-8.
- `s2i_users`: the last admin can neither be deleted nor demoted; a password
  set by someone else forces a change on the next login (unless
  `must_change_password: false`). User changes go to the audit log
  (`user_put`, `user_delete`, `password_change`; never password material).
- Sessions (`s2i_web_session`): ETS keyed by SHA-256 of the token; idle 30
  min, absolute 12 h (`s2i_web` `session_idle_timeout` / `session_max_age`).
  Only the user name is stored; role and pending password change are read
  per request, so role changes apply at once. Deleting a user or resetting
  their password ends their sessions; changing the own password ends the
  other sessions. Sessions do not survive a restart.
- While a password change is pending, only `me`, `me/password` and `logout`
  are allowed (403 `password_change_required`).
- CSRF header: `X-Requested-With` (any value) on every method except
  GET/HEAD, including login.
- `Secure` is set on the cookie when the request came over HTTPS (a plain
  HTTP listener is meant for localhost / reverse proxies).
- Bootstrap admin (no users at all): name `admin_user` (default `admin`),
  password from `$S2I_ADMIN_PASSWORD`, else `admin_password`, else a
  random one written to `initial_password_file` (default
  `data/initial_admin_password`, 0600) — never logged.

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

As implemented (phase 7):

- `s2i_debug` (`s2i_core`, so the SNMP and IEC sides can publish without
  depending on the web app): `publish/2` sends `{s2i_debug, Topic, Event}`
  to the `pg` members of the topic; producers that build costly events
  check `active/1` first (one ETS lookup). `publish/2` never fails, also
  while `s2i_debug_sup` restarts. `traps`, `log` and `iec:*` are *buffered*:
  they pass through the `s2i_debug` process, which keeps the newest 200
  (`log`: 500) per topic and returns them on `subscribe/1`. Values and SNMP
  traces go straight from the producer to the subscribers; a value
  subscriber gets the current values from `s2i_live` instead of a history.
- Producers: `s2i_device` publishes every routed value with the IEC writes
  it caused (`values:device:*`, source poll / trap / auto_reset / down),
  requests, responses, timeouts, errors and reports (`snmp:trace:*`), and
  every trap with matched rules and misses (`traps`; traps from unknown
  agents via `s2i_snmpm_user`); `s2i_iec:publish/2` the accepted values
  (`values:server:*`); `s2i_iec_callback` connection events (`iec:*`; the
  connection pid, as erl60870 reports no peer address). The `logger`
  handler `s2i_debug_log` (level `s2i_core` `debug_log_level`, default
  `info`) feeds `log`.
- `/ws` (`s2i_web_ws`, protocol in `s2i_web_ws_proto`): the upgrade needs a
  session with `viewer` access and an `Origin` of the gateway's own host
  (or `s2i_web` `ws_allowed_origins`), against cross-site WebSocket
  hijacking. Client: `{"op": "subscribe" | "unsubscribe", "topic", "level"}`,
  `{"op": "ping"}`. Server: `subscribed` (history, `snapshot` for value
  topics, `groups` for `iec:*`), `event`, `groups` (every 2 s for
  subscribed servers), `dropped`, `error`, `pong`. At most 32 topics per
  connection and 500 events/s (`ws_rate_limit`; excess dropped and
  counted). The session is checked every second without refreshing it: an
  open debug view does not keep a session alive, and logout, expiry, user
  deletion or a forced password change close the socket with code 4001.
- UI (`frontend/`, React 19 + TypeScript + Vite + TanStack Query, served
  by `s2i_web_static` with a strict CSP and SPA fallback): entity forms
  are generated from the OpenAPI schemas (objects, discriminated unions,
  maps, arrays, scalar `oneOf`), with the gateway's validation errors shown
  at their fields and a raw JSON tab; stored secrets stay envelopes unless
  replaced. Types come from the OpenAPI document (`openapi-typescript`).

## 10. Testing strategy

| Layer | Tests |
|---|---|
| `s2i_transform`, `s2i_expand`, `s2i_validate`, `s2i_routes`, `s2i_resolve`, `s2i_reconcile`, `s2i_sample`, `s2i_poll`, `s2i_snmp_conf`, `s2i_trap_match`, ordering rule | eunit + PropEr, written before the code |
| `s2i_config` + Mnesia | common_test, fresh schema per suite |
| SNMP | common_test: OTP `snmpa` (v3, spike, traps) and a scripted v1/v2c agent (`s2i_fake_agent`: values, tables, silence, reboots) |
| IEC | common_test with a minimal test master (APCI + `iec60870_asdu` codec: STARTDT, GI, receive spontaneous) |
| End to end | `snmpa` → gateway → test master, incl. linkDown race and device-down quality |
| REST / WS | `httpc` against the whole gateway (`s2i_web_SUITE`); `gun` for the WebSocket (session, origin, every topic, close on logout) |
| Debug topics | `s2i_debug_SUITE` (history, bounds, logger handler, publish while down); eunit for the WS protocol |
| Frontend | Vitest + React Testing Library: pure models (form logic, debug reducers, WebSocket client with fake sockets, config diff), components, and every page rendered against API responses recorded from a running gateway |

`rebar3 check` alias: compile + eunit + xref + dialyzer (as in erl60870);
`rebar3 ct` separately; CI on OTP 27 and 28.

## 11. Upstream work in erl60870

- **Point removal:** `iec60870_server:remove(Server, [{Coa, Ioa}])`, new
  optional data-model callback `delete/3` (implemented in `iec60870_dm_ets`),
  so removed IOAs no longer answer interrogation. Released in erl60870
  v0.2.0, which this project depends on.

## 12. Implementation phases

0. Umbrella skeleton, rebar3 aliases, CI, erl60870 dependency
1. Config schema (incl. transform parameters), validation, Mnesia store,
   staged/active versions, audit, export/import
2. Profile expansion + IOA collision check, overrides, instance resolution,
   transforms, route compiler (pure)
3. IEC side: reconciler, callback, quality seeding (+ upstream `remove/2`)
4. SNMP polling: 4a snmpm spike, 4b v1/v2c, 4c v3/USM (incl. engine id
   discovery), device health
5. Traps/informs: varbind match, trap rules, ordering rule, confirm-GET
6. REST API + auth (users, sessions, CSRF, OpenAPI, status, SNMP tools)
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
| 11 | Routing in profiles | target labels in profile mappings, bound to servers per device |
| 12 | Secrets at rest | AES-256-GCM envelopes, key from a 0600 key file (not env) |
| 13 | Poll groups | timers inside the one `s2i_device` process per device (own snmpm user each), not one process per group |
| 14 | Trap rule targets | datapoint template + table index from a varbind (`suffix` or `value`), looked up per template in the compiled routes; never by guessed index |

## 15. Open points and planned extensions

- **IEC peer addresses in the debug view:** erl60870's `connection_event/2`
  carries only the connection pid, and `iec60870_rgroup:info/1` only member
  pids; showing the SCADA's IP per connection needs the peer address from
  erl60870 (upstream, like §11). `s2i_iec:groups/1` relies on erl60870's
  registry names (`{rgroup_sup, Name}`), which are not a documented API.

- **Interface traffic / error metrics** (octet rates, errors, discards): not
  needed in v1, but the design keeps them cheap to add: `rate`/`counter`
  transforms with wrap handling and `sysUpTime`-based discontinuity reset,
  separate poll groups per profile (e.g. `counters => 60000`), and HC
  (64-bit) counters on v2c/v3. If the number of OIDs per device grows a lot,
  add GETBULK-based table polling as an alternative to chunked GET.
