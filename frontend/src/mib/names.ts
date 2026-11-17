// OID ↔ name lookups against the MIB library (POST /oids/translate), shared
// by every table that shows OIDs. Requests of one render pass are batched
// into one call; results are cached until the library changes
// (resetOidNames). A failed lookup counts as "no name": OIDs stay numeric.
import { useEffect, useSyncExternalStore } from "react";
import { post } from "../api/client";
import type { OidInfo } from "../api/types";

export interface NameResult {
  name: string;
  oid?: string;
  error?: string;
  modules?: string[];
}

const MAX_BATCH = 1000;

const oids = new Map<string, OidInfo | null>();
const names = new Map<string, NameResult>();
const pendingOids = new Set<string>();
const pendingNames = new Set<string>();
const listeners = new Set<() => void>();
let timer: ReturnType<typeof setTimeout> | null = null;
let version = 0;

export const normOid = (oid: string) => oid.trim().replace(/^\./, "");

function notify() {
  version++;
  listeners.forEach((l) => l());
}

function schedule() {
  if (timer === null) timer = setTimeout(flush, 0);
}

async function flush() {
  timer = null;
  const os = [...pendingOids].slice(0, MAX_BATCH);
  const ns = [...pendingNames].slice(0, MAX_BATCH - os.length);
  if (os.length + ns.length === 0) return;
  let res: { oids: (OidInfo | null)[]; names: NameResult[] } | undefined;
  try {
    res = await post<{ oids: (OidInfo | null)[]; names: NameResult[] }>("oids/translate", { oids: os, names: ns });
  } catch {
    res = undefined;
  }
  os.forEach((o, i) => {
    pendingOids.delete(o);
    oids.set(o, res?.oids[i] ?? null);
  });
  ns.forEach((n, i) => {
    pendingNames.delete(n);
    names.set(n, res?.names[i] ?? { name: n, error: "unavailable" });
  });
  notify();
  if (pendingOids.size + pendingNames.size > 0) schedule();
}

/** Ask for names of these numeric OIDs (no-op for known or pending ones). */
export function requestOids(list: string[]) {
  let added = false;
  for (const raw of list) {
    const o = normOid(raw);
    if (!/^\d+(\.\d+)*$/.test(o) || oids.has(o) || pendingOids.has(o)) continue;
    pendingOids.add(o);
    added = true;
  }
  if (added) schedule();
}

export function requestNames(list: string[]) {
  let added = false;
  for (const n of list) {
    if (names.has(n) || pendingNames.has(n)) continue;
    pendingNames.add(n);
    added = true;
  }
  if (added) schedule();
}

/** The cached translation: undefined while unknown, null if the OID has no name. */
export const peekOid = (oid: string): OidInfo | null | undefined => oids.get(normOid(oid));
export const peekName = (name: string): NameResult | undefined => names.get(name);

/** Forget everything (after an upload or delete). */
export function resetOidNames() {
  oids.clear();
  names.clear();
  notify();
}

function subscribe(l: () => void) {
  listeners.add(l);
  return () => listeners.delete(l);
}

/** Re-render on new translations; returns a counter that changes with them. */
export function useOidNamesVersion(): number {
  return useSyncExternalStore(subscribe, () => version);
}

/** Names for a set of OIDs; the returned lookup is current for this render. */
export function useOidInfos(list: string[]): (oid: string) => OidInfo | null | undefined {
  useOidNamesVersion();
  const key = list.join(" ");
  useEffect(() => requestOids(key ? key.split(" ") : []), [key]);
  return peekOid;
}

export function useOidInfo(oid: string | undefined): OidInfo | null | undefined {
  useOidNamesVersion();
  useEffect(() => {
    if (oid) requestOids([oid]);
  }, [oid]);
  return oid ? peekOid(oid) : undefined;
}

export function useResolvedName(name: string | undefined): NameResult | undefined {
  useOidNamesVersion();
  useEffect(() => {
    if (name) requestNames([name]);
  }, [name]);
  return name ? peekName(name) : undefined;
}

// --- formatting ------------------------------------------------------------------

/** `ifOperStatus.3`, or the numeric OID without a name. */
export function oidLabel(oid: string, info: OidInfo | null | undefined): string {
  if (!info) return normOid(oid);
  return info.index ? `${info.name}.${info.index}` : info.name;
}

/** The enum label of an integer value (`up` for ifOperStatus = 1). */
export function enumLabel(info: OidInfo | null | undefined, value: unknown): string | undefined {
  if (!info?.enums || typeof value !== "number") return undefined;
  return info.enums.find((e) => e.value === value)?.name;
}

/** Text of an OID for filters: numeric plus the name when known. */
export function oidText(oid: string): string {
  const info = peekOid(oid);
  return info ? `${normOid(oid)} ${info.module}::${oidLabel(oid, info)}` : oid;
}
