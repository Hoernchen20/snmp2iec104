import { useMemo, useState, type ReactNode } from "react";
import { Link, useSearchParams } from "react-router";
import { useStatus } from "../api/hooks";
import { QualityBadges, Tabs } from "../components/ui";
import { useSocketState, useTopic } from "../debug/context";
import {
  compareAddr,
  compareOid,
  deviceReducer,
  emptyDevice,
  emptyList,
  emptyServer,
  eventListReducer,
  formatIec,
  formatSnmp,
  formatTime,
  serverReducer,
  type EventList,
  type SnmpValue,
} from "../debug/model";

type View = "device" | "server" | "trace" | "traps" | "iec" | "log";

const VIEWS: { id: View; label: string }[] = [
  { id: "device", label: "Device values" },
  { id: "server", label: "Server values" },
  { id: "trace", label: "SNMP trace" },
  { id: "traps", label: "Traps" },
  { id: "iec", label: "IEC connections" },
  { id: "log", label: "Log" },
];

const LEVELS = ["debug", "info", "notice", "warning", "error"];

export function DebugPage() {
  const [params, setParams] = useSearchParams();
  const view = (VIEWS.some((v) => v.id === params.get("view")) ? params.get("view") : "device") as View;
  const name = params.get("name") ?? "";
  const level = params.get("level") ?? "info";
  const status = useStatus(30000);
  const devices = (status.data?.devices ?? []).map((d) => d.name);
  const servers = (status.data?.servers ?? []).map((s) => s.name);
  const set = (p: Record<string, string>) => setParams({ view, ...(name ? { name } : {}), ...p });
  const choices = view === "device" || view === "trace" ? devices : view === "server" || view === "iec" ? servers : null;
  return (
    <div className="page">
      <div className="page-head">
        <h1>Live debug</h1>
        <SocketIndicator />
      </div>
      <Tabs tabs={VIEWS} value={view} onChange={(v) => setParams({ view: v, ...(name ? { name } : {}) })} />
      {choices ? (
        <label className="field">
          <span className="label">{view === "device" || view === "trace" ? "Device" : "Server"}</span>
          <select value={name} onChange={(e) => set({ name: e.target.value })} aria-label="name">
            <option value="">— choose —</option>
            {choices.map((n) => (
              <option key={n} value={n}>
                {n}
              </option>
            ))}
            {name && !choices.includes(name) ? <option value={name}>{name}</option> : null}
          </select>
        </label>
      ) : null}
      {view === "log" ? (
        <label className="field">
          <span className="label">Minimum level</span>
          <select value={level} onChange={(e) => setParams({ view, level: e.target.value })} aria-label="level">
            {LEVELS.map((l) => (
              <option key={l}>{l}</option>
            ))}
          </select>
        </label>
      ) : null}
      {view === "device" && name ? <DeviceValues name={name} /> : null}
      {view === "server" && name ? <ServerValues name={name} /> : null}
      {view === "trace" && name ? <Trace name={name} /> : null}
      {view === "iec" && name ? <Iec name={name} /> : null}
      {view === "traps" ? <Traps /> : null}
      {view === "log" ? <Log level={level} /> : null}
    </div>
  );
}

function SocketIndicator() {
  const { state, dropped } = useSocketState();
  const label = { connecting: "connecting", open: "live", reconnecting: "reconnecting…", ended: "session ended" }[state];
  return (
    <span className={`badge ${state === "open" ? "ok" : state === "ended" ? "bad" : "warn"}`} title="WebSocket">
      {label}
      {dropped > 0 ? ` · ${dropped} dropped (rate limit)` : ""}
    </span>
  );
}

// --- values ------------------------------------------------------------------------

function DeviceValues({ name }: { name: string }) {
  const [s] = useTopic(`values:device:${name}`, deviceReducer, emptyDevice);
  const points = Object.values(s.points).sort((a, b) => a.server.localeCompare(b.server) || compareAddr(a, b));
  const oids = Object.values(s.oids).sort((a, b) => compareOid(a.oid, b.oid));
  return (
    <>
      {s.error ? <div className="alert error">{s.error}</div> : null}
      {s.downAt ? <div className="alert warn">Device went down at {formatTime(s.downAt)}: its points were invalidated.</div> : null}
      <h2>IEC points of {name}</h2>
      {points.length === 0 ? (
        <p className="muted">No points (device not in the active configuration, or no mappings).</p>
      ) : (
        <table className="compact">
          <thead>
            <tr>
              <th>Server</th>
              <th className="num">COA</th>
              <th className="num">IOA</th>
              <th>Datapoint</th>
              <th>Type</th>
              <th>Value</th>
              <th>Quality</th>
              <th>Updated</th>
            </tr>
          </thead>
          <tbody>
            {points.map((p) => (
              <tr key={`${p.server}|${p.coa}|${p.ioa}`}>
                <td>{p.server}</td>
                <td className="num">{p.coa}</td>
                <td className="num">{p.ioa}</td>
                <td>{p.source}</td>
                <td className="mono">{p.point.type}</td>
                <td className="mono">{formatIec(p.point)}</td>
                <td>
                  <QualityBadges quality={p.point.quality} />
                </td>
                <td>{formatTime(p.at ?? p.point.ts)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      <h2>SNMP values received</h2>
      <p className="muted">Every routed value as it arrives (poll, trap, auto reset); "sent" = IEC updates it caused (unchanged values and values within the deadband cause none).</p>
      {oids.length === 0 ? (
        <p className="muted">Waiting for the next poll…</p>
      ) : (
        <table className="compact">
          <thead>
            <tr>
              <th>OID</th>
              <th>Datapoint</th>
              <th>Value</th>
              <th>Via</th>
              <th className="num">Sent</th>
              <th>At</th>
            </tr>
          </thead>
          <tbody>
            {oids.map((o) => (
              <tr key={o.oid}>
                <td className="mono">{o.oid}</td>
                <td>{o.datapoints.join(", ")}</td>
                <td className="mono" title={o.value.type}>
                  {formatSnmp(o.value)}
                </td>
                <td>{o.source.replace(/_/g, " ")}</td>
                <td className="num">{o.sent}</td>
                <td>{formatTime(o.at)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </>
  );
}

function ServerValues({ name }: { name: string }) {
  const [s] = useTopic(`values:server:${name}`, serverReducer, emptyServer);
  const [filter, setFilter] = useState("");
  const points = Object.values(s.points)
    .filter((p) => !filter || `${p.coa}/${p.ioa}`.includes(filter) || String(p.ioa) === filter)
    .sort(compareAddr);
  return (
    <>
      {s.error ? <div className="alert error">{s.error}</div> : null}
      <div className="toolbar">
        <input placeholder="Filter IOA" value={filter} onChange={(e) => setFilter(e.target.value)} aria-label="filter" />
        <span className="muted">{Object.keys(s.points).length} points</span>
      </div>
      <table className="compact">
        <thead>
          <tr>
            <th className="num">COA</th>
            <th className="num">IOA</th>
            <th>Type</th>
            <th>Value</th>
            <th>Quality</th>
            <th>Time tag</th>
            <th>Updated</th>
          </tr>
        </thead>
        <tbody>
          {points.map((p) => (
            <tr key={`${p.coa}|${p.ioa}`}>
              <td className="num">{p.coa}</td>
              <td className="num">{p.ioa}</td>
              <td className="mono">{p.type}</td>
              <td className="mono">{formatIec(p)}</td>
              <td>
                <QualityBadges quality={p.quality} />
              </td>
              <td>{formatTime(p.ts)}</td>
              <td>{formatTime(p.at)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </>
  );
}

// --- event lists -------------------------------------------------------------------

/* eslint-disable @typescript-eslint/no-explicit-any */
type Ev = Record<string, any>;

function EventTable({
  list,
  clear,
  head,
  row,
  text,
}: {
  list: EventList<Ev>;
  clear: () => void;
  head: ReactNode;
  row: (e: Ev) => ReactNode;
  text: (e: Ev) => string;
}) {
  const [paused, setPaused] = useState<Ev[] | null>(null);
  const [filter, setFilter] = useState("");
  const shown = useMemo(() => {
    const evs = paused ?? list.events;
    const f = filter.toLowerCase();
    return (f ? evs.filter((e) => text(e).toLowerCase().includes(f)) : evs).slice().reverse();
  }, [paused, list.events, filter, text]);
  return (
    <>
      {list.error ? <div className="alert error">{list.error}</div> : null}
      <div className="toolbar">
        <input placeholder="Filter" value={filter} onChange={(e) => setFilter(e.target.value)} aria-label="filter" />
        <button type="button" onClick={() => setPaused(paused ? null : list.events)}>
          {paused ? "Resume" : "Pause"}
        </button>
        <button
          type="button"
          onClick={() => {
            clear();
            setPaused(null);
          }}
        >
          Clear
        </button>
        <span className="muted">
          {shown.length} of {list.events.length} events{paused ? " (paused)" : ""}, newest first
        </span>
      </div>
      <table className="compact events">
        <thead>{head}</thead>
        <tbody>{shown.map((e, i) => <tr key={shown.length - i}>{row(e)}</tr>)}</tbody>
      </table>
    </>
  );
}

const vbText = (vbs: Ev[] | undefined) =>
  (vbs ?? []).map((v) => `${v.oid} = ${formatSnmp(v as SnmpValue)}`).join("\n");

function Trace({ name }: { name: string }) {
  const [list, clear] = useTopic<EventList<Ev>>(`snmp:trace:${name}`, eventListReducer, emptyList);
  return (
    <>
      <p className="muted">Requests of {name} and what came back: polls, instance resolution, one-off GETs and tool requests.</p>
      <EventTable
        list={list}
        clear={clear}
        text={traceText}
        head={
          <tr>
            <th>Time</th>
            <th>Dir</th>
            <th className="num">Req</th>
            <th>What</th>
            <th>Details</th>
          </tr>
        }
        row={(e) => (
          <>
            <td>{formatTime(e.at)}</td>
            <td>
              <span className={`badge ${e.dir === "response" ? "ok" : e.dir === "request" ? "muted" : "bad"}`}>{e.dir}</span>
            </td>
            <td className="num">{e.req_id ?? ""}</td>
            <td>{traceWhat(e)}</td>
            <td className="mono pre">{traceDetails(e)}</td>
          </>
        )}
      />
    </>
  );
}

function traceWhat(e: Ev): string {
  if (e.dir === "request") {
    const p = e.purpose;
    const why = typeof p === "string" ? p : p?.poll ? `poll ${p.poll}` : p?.resolve ? `resolve ${p.resolve}` : "";
    return `${e.op} ${why}${e.attempt > 0 ? ` (retry ${e.attempt})` : ""}`;
  }
  if (e.dir === "response") return `${e.error_status}${e.error_index ? ` @${e.error_index}` : ""}${e.late ? " (late)" : ""}`;
  return e.dir;
}

function traceDetails(e: Ev): string {
  if (e.dir === "request") return (e.oids ?? []).join("\n") + (e.error ? `\nerror: ${e.error}` : "");
  if (e.dir === "response") return vbText(e.varbinds);
  return String(e.reason ?? e.info ?? "");
}

const traceText = (e: Ev) => `${traceWhat(e)} ${traceDetails(e)}`;

function Traps() {
  const [list, clear] = useTopic<EventList<Ev>>("traps", eventListReducer, emptyList);
  return (
    <EventTable
      list={list}
      clear={clear}
      text={(e) => `${e.device ?? e.from} ${e.trap_oid} ${vbText(e.varbinds)}`}
      head={
        <tr>
          <th>Time</th>
          <th>Device</th>
          <th>Trap OID</th>
          <th>Matched</th>
          <th>Varbinds</th>
        </tr>
      }
      row={(e) => (
        <>
          <td>{formatTime(e.at)}</td>
          <td>{e.device ? <Link to={`/devices/${encodeURIComponent(e.device)}`}>{e.device}</Link> : <span className="badge warn">unknown {e.from}</span>}</td>
          <td className="mono">{e.trap_oid ?? "—"}</td>
          <td>
            {(e.matched ?? []).length === 0 ? (
              <span className="badge muted">unmatched</span>
            ) : (
              (e.matched as string[]).map((m) => (
                <span key={m} className="badge ok">
                  {m === "varbind" ? "datapoint varbind" : `rule ${m}`}
                </span>
              ))
            )}
            {(e.misses ?? []).map((m: Ev) => (
              <span key={m.rule} className="badge warn" title={m.reason}>
                rule {m.rule}: {String(m.reason).replace(/_/g, " ")}
              </span>
            ))}
          </td>
          <td className="mono pre">{vbText(e.varbinds)}</td>
        </>
      )}
    />
  );
}

function Iec({ name }: { name: string }) {
  const [list, clear] = useTopic<EventList<Ev>>(`iec:${name}`, eventListReducer, emptyList);
  return (
    <>
      <h2>Redundancy groups</h2>
      {list.groups === undefined ? null : list.groups.length === 0 ? (
        <p className="muted">No group (server not running, or no connection in per-connection mode).</p>
      ) : (
        <table className="compact">
          <thead>
            <tr>
              <th>Group</th>
              <th>Active connection</th>
              <th className="num">Connections</th>
              <th className="num">Unacknowledged ASDUs</th>
            </tr>
          </thead>
          <tbody>
            {list.groups.map((g, i) => (
              <tr key={i}>
                <td>{g.name}</td>
                <td>{g.active ? <span className="badge ok">yes</span> : <span className="badge warn">none</span>}</td>
                <td className="num">{g.members}</td>
                <td className="num">{g.buffer_len}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      <h2>Connection events</h2>
      <EventTable
        list={list}
        clear={clear}
        text={(e) => `${e.event} ${e.conn} ${e.reason ?? ""}`}
        head={
          <tr>
            <th>Time</th>
            <th>Event</th>
            <th>Connection</th>
            <th>Reason</th>
          </tr>
        }
        row={(e) => (
          <>
            <td>{formatTime(e.at)}</td>
            <td>
              <span className={`badge ${e.event === "activated" ? "ok" : e.event === "down" ? "bad" : "warn"}`}>{e.event}</span>
            </td>
            <td className="mono">{e.conn}</td>
            <td className="mono">{e.reason ?? ""}</td>
          </>
        )}
      />
    </>
  );
}

function Log({ level }: { level: string }) {
  const [list, clear] = useTopic<EventList<Ev>>("log", eventListReducer, emptyList, { level });
  return (
    <EventTable
      list={list}
      clear={clear}
      text={(e) => `${e.level} ${e.msg} ${e.mfa ?? ""}`}
      head={
        <tr>
          <th>Time</th>
          <th>Level</th>
          <th>Message</th>
          <th>Where</th>
        </tr>
      }
      row={(e) => (
        <>
          <td>{formatTime(e.at)}</td>
          <td>
            <span className={`badge ${["error", "critical", "alert", "emergency"].includes(e.level) ? "bad" : e.level === "warning" ? "warn" : "muted"}`}>
              {e.level}
            </span>
          </td>
          <td className="pre">{e.msg}</td>
          <td className="mono small">{e.mfa ?? ""}</td>
        </>
      )}
    />
  );
}
/* eslint-enable @typescript-eslint/no-explicit-any */
