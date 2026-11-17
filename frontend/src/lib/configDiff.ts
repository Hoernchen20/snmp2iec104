// What activating the staged configuration changes, per entity.
import type { Config } from "../api/types";

export type Change = "added" | "removed" | "changed";

export interface EntityChange {
  kind: "servers" | "devices" | "profiles";
  name: string;
  change: Change;
  /** Top-level fields that differ (changed entities only). */
  fields: string[];
}

const KINDS = ["servers", "devices", "profiles"] as const;

/** Stable JSON: object keys sorted, so key order never counts as a change. */
export function canonical(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(canonical).join(",")}]`;
  if (v && typeof v === "object") {
    const o = v as Record<string, unknown>;
    return `{${Object.keys(o)
      .sort()
      .map((k) => `${JSON.stringify(k)}:${canonical(o[k])}`)
      .join(",")}}`;
  }
  return JSON.stringify(v);
}

export function diffConfigs(staged: Config, active: Config | null): EntityChange[] {
  const out: EntityChange[] = [];
  for (const kind of KINDS) {
    const s = (staged[kind] ?? {}) as Record<string, Record<string, unknown>>;
    const a = (active?.[kind] ?? {}) as Record<string, Record<string, unknown>>;
    for (const name of Object.keys(s).sort()) {
      if (!(name in a)) out.push({ kind, name, change: "added", fields: [] });
      else if (canonical(s[name]) !== canonical(a[name])) {
        const keys = [...new Set([...Object.keys(s[name]), ...Object.keys(a[name])])].sort();
        out.push({
          kind,
          name,
          change: "changed",
          fields: keys.filter((k) => canonical(s[name][k]) !== canonical(a[name][k])),
        });
      }
    }
    for (const name of Object.keys(a).sort()) {
      if (!(name in s)) out.push({ kind, name, change: "removed", fields: [] });
    }
  }
  return out;
}
