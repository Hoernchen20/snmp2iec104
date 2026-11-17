import { describe, expect, it } from "vitest";
import type { Config } from "../api/types";
import { canonical, diffConfigs } from "./configDiff";

const cfg = (c: Partial<Record<keyof Config, Record<string, unknown>>>) =>
  ({ servers: {}, devices: {}, profiles: {}, ...c }) as unknown as Config;

describe("diffConfigs", () => {
  it("lists added, removed and changed entities with the changed fields", () => {
    const active = cfg({
      devices: { a: { name: "a", host: "10.0.0.1", port: 161 }, gone: { name: "gone" } },
      servers: { s: { name: "s", params: { k: 12, w: 8 } } },
    });
    const staged = cfg({
      devices: { a: { name: "a", host: "10.0.0.2", port: 161 }, fresh: { name: "fresh" } },
      servers: { s: { params: { w: 8, k: 12 }, name: "s" } }, // same, other key order
    });
    expect(diffConfigs(staged, active)).toEqual([
      { kind: "devices", name: "a", change: "changed", fields: ["host"] },
      { kind: "devices", name: "fresh", change: "added", fields: [] },
      { kind: "devices", name: "gone", change: "removed", fields: [] },
    ]);
  });

  it("treats everything as added before the first activation", () => {
    expect(diffConfigs(cfg({ profiles: { p: { name: "p" } } }), null)).toEqual([
      { kind: "profiles", name: "p", change: "added", fields: [] },
    ]);
  });

  it("canonical JSON ignores key order but not array order", () => {
    expect(canonical({ b: 1, a: [1, 2] })).toBe(canonical({ a: [1, 2], b: 1 }));
    expect(canonical([1, 2])).not.toBe(canonical([2, 1]));
  });
});
