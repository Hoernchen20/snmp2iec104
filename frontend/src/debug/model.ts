// Pure state of the debug views, fed with the messages of one topic.
import type { GroupStatus, ServerMsg } from "./socket";

export interface IecPoint {
  type: string;
  value: unknown;
  quality: string[];
  ts?: number;
  [k: string]: unknown;
}

export interface SnmpValue {
  type: string;
  value?: unknown;
  hex?: string;
}

export interface Write {
  server: string;
  coa: number;
  ioa: number;
  point?: IecPoint;
  invalid?: boolean;
}

// --- event lists (traps, trace, log, iec) -------------------------------------

export const MAX_EVENTS = 1000;

export interface EventList<E = Record<string, unknown>> {
  events: E[];
  groups?: GroupStatus[];
  error?: string;
}

export const emptyList: EventList = { events: [] };

export function eventListReducer<E>(state: EventList<E>, msg: ServerMsg): EventList<E> {
  switch (msg.type) {
    case "subscribed": {
      // a buffered topic sends its history again after a reconnect
      const events = msg.history.length > 0 ? (msg.history as E[]).slice(-MAX_EVENTS) : state.events;
      return { ...state, events, groups: msg.groups ?? state.groups, error: undefined };
    }
    case "event": {
      const events = [...state.events, msg.event as E];
      return { ...state, events: events.length > MAX_EVENTS ? events.slice(-MAX_EVENTS) : events };
    }
    case "groups":
      return { ...state, groups: msg.groups };
    case "error":
      return { ...state, error: msg.error };
    default:
      return state;
  }
}

// --- values of one device ---------------------------------------------------------

export interface DevicePointRow {
  server: string;
  coa: number;
  ioa: number;
  source: string;
  point: IecPoint;
  at?: number;
}

export interface OidRow {
  oid: string;
  value: SnmpValue;
  datapoints: string[];
  source: string;
  at: number;
  sent: number;
}

export interface DeviceValues {
  points: Record<string, DevicePointRow>;
  oids: Record<string, OidRow>;
  downAt?: number;
  error?: string;
}

export const emptyDevice: DeviceValues = { points: {}, oids: {} };

export const pointKey = (server: string, coa: number, ioa: number) => `${server}|${coa}|${ioa}`;

function applyWrites(points: Record<string, DevicePointRow>, writes: Write[], at: number) {
  const next = { ...points };
  for (const w of writes) {
    const k = pointKey(w.server, w.coa, w.ioa);
    const old = next[k];
    if (!old) continue; // not (yet) in the snapshot
    next[k] = {
      ...old,
      at,
      point: w.invalid ? { ...old.point, quality: ["invalid"] } : (w.point as IecPoint),
    };
  }
  return next;
}

export function deviceReducer(state: DeviceValues, msg: ServerMsg): DeviceValues {
  switch (msg.type) {
    case "subscribed": {
      const points: Record<string, DevicePointRow> = {};
      for (const p of msg.snapshot ?? []) points[pointKey(p.server, p.coa, p.ioa)] = p;
      return { ...state, points, error: undefined };
    }
    case "event": {
      const ev = msg.event as { at: number; source: string; values?: OidValueEvent[]; writes?: Write[] };
      if (ev.source === "down") {
        return { ...state, downAt: ev.at, points: applyWrites(state.points, ev.writes ?? [], ev.at) };
      }
      const oids = { ...state.oids };
      let points = state.points;
      for (const v of ev.values ?? []) {
        oids[v.oid] = { oid: v.oid, value: v.value, datapoints: v.datapoints, source: ev.source, at: ev.at, sent: v.writes.length };
        points = applyWrites(points, v.writes, ev.at);
      }
      return { ...state, oids, points };
    }
    case "error":
      return { ...state, error: msg.error };
    default:
      return state;
  }
}

interface OidValueEvent {
  oid: string;
  value: SnmpValue;
  datapoints: string[];
  writes: Write[];
}

// --- values of one IEC server ---------------------------------------------------------

export interface ServerPointRow extends IecPoint {
  coa: number;
  ioa: number;
  at?: number;
}

export interface ServerValues {
  points: Record<string, ServerPointRow>;
  error?: string;
}

export const emptyServer: ServerValues = { points: {} };

export function serverReducer(state: ServerValues, msg: ServerMsg): ServerValues {
  switch (msg.type) {
    case "subscribed": {
      const points: Record<string, ServerPointRow> = {};
      for (const p of msg.snapshot ?? []) points[`${p.coa}|${p.ioa}`] = p;
      return { points };
    }
    case "event": {
      const ev = msg.event as { at: number; points: ServerPointRow[] };
      const points = { ...state.points };
      for (const p of ev.points) points[`${p.coa}|${p.ioa}`] = { ...p, at: ev.at };
      return { ...state, points };
    }
    case "error":
      return { ...state, error: msg.error };
    default:
      return state;
  }
}

// --- formatting ---------------------------------------------------------------------------

export function formatSnmp(v: SnmpValue | undefined): string {
  if (!v) return "";
  if (v.value === undefined) return v.type.replace(/_/g, " ");
  if (v.value === null) return `0x${v.hex ?? ""}`;
  return String(v.value);
}

export function formatIec(p: IecPoint | undefined): string {
  if (!p) return "";
  const v = p.value;
  if (typeof v === "number" && !Number.isInteger(v)) return String(Math.round(v * 1e6) / 1e6);
  return String(v);
}

export function formatTime(ms: number | undefined): string {
  if (ms === undefined) return "";
  const d = new Date(ms);
  const pad = (n: number, w = 2) => String(n).padStart(w, "0");
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}.${pad(d.getMilliseconds(), 3)}`;
}

export function compareAddr(a: { coa: number; ioa: number }, b: { coa: number; ioa: number }): number {
  return a.coa - b.coa || a.ioa - b.ioa;
}

/** Numeric OID order (1.3.6.1.2 < 1.3.6.1.10). */
export function compareOid(a: string, b: string): number {
  const x = a.split(".").map(Number);
  const y = b.split(".").map(Number);
  for (let i = 0; i < Math.min(x.length, y.length); i++) if (x[i] !== y[i]) return x[i] - y[i];
  return x.length - y.length;
}
