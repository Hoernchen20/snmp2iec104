import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { OidInfo } from "../api/types";
import {
  enumLabel,
  oidLabel,
  oidText,
  peekName,
  peekOid,
  requestNames,
  requestOids,
  resetOidNames,
} from "./names";

const oper: OidInfo = {
  oid: "1.3.6.1.2.1.2.2.1.8.3",
  base_oid: "1.3.6.1.2.1.2.2.1.8",
  index: "3",
  name: "ifOperStatus",
  module: "IF-MIB",
  kind: "column",
  enums: [
    { value: 1, name: "up" },
    { value: 2, name: "down" },
  ],
};

let calls: { oids: string[]; names: string[] }[];

function serve(fail = false) {
  calls = [];
  vi.stubGlobal(
    "fetch",
    vi.fn(async (_url: string, init: RequestInit) => {
      const body = JSON.parse(String(init.body)) as { oids: string[]; names: string[] };
      calls.push(body);
      if (fail) return new Response(JSON.stringify({ error: "internal_error" }), { status: 500 });
      return new Response(
        JSON.stringify({
          oids: body.oids.map((o) => (o === oper.oid ? oper : null)),
          names: body.names.map((n) => (n === "ifOperStatus" ? { name: n, oid: oper.base_oid } : { name: n, error: "not_found" })),
        }),
        { status: 200 },
      );
    }),
  );
}

const settle = () => new Promise((r) => setTimeout(r, 10));

describe("OID names", () => {
  beforeEach(() => resetOidNames());
  afterEach(() => vi.unstubAllGlobals());

  it("batches the requests of one tick into one call and caches", async () => {
    serve();
    requestOids([oper.oid, "1.3.6.1.9"]);
    requestOids(["." + oper.oid]);
    requestNames(["ifOperStatus", "nope"]);
    expect(peekOid(oper.oid)).toBeUndefined();
    await settle();
    expect(calls).toEqual([{ oids: [oper.oid, "1.3.6.1.9"], names: ["ifOperStatus", "nope"] }]);
    expect(peekOid(oper.oid)).toEqual(oper);
    expect(peekOid(".1.3.6.1.9")).toBeNull();
    expect(peekName("ifOperStatus")?.oid).toBe(oper.base_oid);
    expect(peekName("nope")?.error).toBe("not_found");
    requestOids([oper.oid]);
    await settle();
    expect(calls).toHaveLength(1);
  });

  it("ignores what is not a numeric OID", async () => {
    serve();
    requestOids(["ifIndex", "1.3.{index}", ""]);
    await settle();
    expect(calls).toHaveLength(0);
  });

  it("treats a failed call as no names and asks again after a reset", async () => {
    serve(true);
    requestOids([oper.oid]);
    await settle();
    expect(peekOid(oper.oid)).toBeNull();
    serve();
    resetOidNames();
    requestOids([oper.oid]);
    await settle();
    expect(peekOid(oper.oid)).toEqual(oper);
  });

  it("formats names, enum labels and filter text", async () => {
    expect(oidLabel(oper.oid, oper)).toBe("ifOperStatus.3");
    expect(oidLabel(".1.3.6", null)).toBe("1.3.6");
    expect(oidLabel(oper.base_oid, { ...oper, index: "" })).toBe("ifOperStatus");
    expect(enumLabel(oper, 2)).toBe("down");
    expect(enumLabel(oper, 9)).toBeUndefined();
    expect(enumLabel(oper, "2")).toBeUndefined();
    expect(enumLabel(null, 1)).toBeUndefined();
    serve();
    requestOids([oper.oid]);
    await settle();
    expect(oidText(oper.oid)).toBe(`${oper.oid} IF-MIB::ifOperStatus.3`);
    expect(oidText("1.2.3")).toBe("1.2.3");
  });
});
