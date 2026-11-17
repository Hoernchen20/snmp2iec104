import { describe, expect, it } from "vitest";
import {
  errorsAt,
  getIn,
  hasErrorsUnder,
  initialValue,
  isEnvelope,
  isMap,
  itemSummary,
  label,
  orderedKeys,
  setIn,
  switchVariant,
  variantOf,
} from "./logic";
import type { JsonSchema } from "./types";

const transport: JsonSchema = {
  discriminator: { propertyName: "kind" },
  oneOf: [
    {
      type: "object",
      required: ["kind"],
      "x-order": ["kind", "port", "ip"],
      properties: {
        kind: { type: "string", const: "tcp" },
        port: { type: "integer", default: 2404 },
        ip: { type: "string", default: "0.0.0.0" },
      },
    },
    {
      type: "object",
      required: ["kind", "certfile"],
      "x-order": ["kind", "port", "ip", "certfile", "verify"],
      properties: {
        kind: { type: "string", const: "tls" },
        port: { type: "integer", default: 19998 },
        ip: { type: "string", default: "0.0.0.0" },
        certfile: { type: "string", minLength: 1 },
        verify: { type: "boolean", default: true },
      },
    },
  ],
};

const server: JsonSchema = {
  type: "object",
  required: ["name", "transport", "common_addresses"],
  "x-order": ["name", "description", "transport", "common_addresses", "background_scan"],
  properties: {
    background_scan: { type: "integer", minimum: 1000 },
    common_addresses: { type: "array", items: { type: "integer" } },
    description: { type: "string" },
    name: { type: "string" },
    transport,
  },
};

describe("schema logic", () => {
  it("orders fields by x-order, unknown ones last", () => {
    expect(orderedKeys(server)).toEqual(["name", "description", "transport", "common_addresses", "background_scan"]);
    expect(orderedKeys({ properties: { b: {}, a: {} }, "x-order": ["a"] })).toEqual(["a", "b"]);
  });

  it("builds initial values from required fields, defaults and constants", () => {
    // union defaults are not applied here: only required fields (kind)
    expect(initialValue(server)).toEqual({ name: "", transport: { kind: "tcp" }, common_addresses: [] });
    expect(initialValue({ type: "integer" })).toBeUndefined();
    expect(initialValue({ type: "string", enum: ["a", "b"] })).toBe("a");
    expect(initialValue({ type: "object", additionalProperties: { type: "integer" } })).toEqual({});
  });

  it("finds and switches union variants, keeping shared fields", () => {
    expect(variantOf(transport, { kind: "tls" })).toBe(transport.oneOf![1]);
    expect(variantOf(transport, { kind: "x" })).toBeUndefined();
    expect(switchVariant(transport, { kind: "tcp", port: 2500, ip: "10.0.0.1" }, "tls")).toEqual({
      kind: "tls",
      certfile: "",
      port: 2500,
      ip: "10.0.0.1",
    });
    expect(switchVariant(transport, { kind: "tls", certfile: "a.pem", port: 1 }, "tcp")).toEqual({ kind: "tcp", port: 1 });
  });

  it("updates nested values immutably and removes undefined keys", () => {
    const v = { a: { b: [1, { c: 2 }] }, d: 1 };
    const w = setIn(v, ["a", "b", 1, "c"], 3);
    expect(w).toEqual({ a: { b: [1, { c: 3 }] }, d: 1 });
    expect(v.a.b[1]).toEqual({ c: 2 });
    expect(setIn(v, ["d"], undefined)).toEqual({ a: { b: [1, { c: 2 }] } });
    expect(setIn(undefined, ["x", 0], "y")).toEqual({ x: ["y"] });
    expect(getIn(w, ["a", "b", 1, "c"])).toBe(3);
    expect(getIn(w, ["a", "zz", 1])).toBeUndefined();
  });

  it("matches server errors to fields", () => {
    const errors = [
      { path: ["transport", "port"], error: "out_of_range" },
      { path: ["name"], error: "required" },
    ];
    expect(errorsAt(errors, ["name"])).toHaveLength(1);
    expect(errorsAt(errors, ["transport"])).toHaveLength(0);
    expect(hasErrorsUnder(errors, ["transport"])).toBe(true);
    expect(hasErrorsUnder(errors, ["common_addresses"])).toBe(false);
  });

  it("recognises maps, envelopes, labels and item summaries", () => {
    expect(isMap({ type: "object", additionalProperties: { type: "integer" } })).toBe(true);
    expect(isMap(server)).toBe(false);
    expect(isEnvelope("enc:v1:abc")).toBe(true);
    expect(isEnvelope("public")).toBe(false);
    expect(label("common_addresses")).toBe("Common addresses");
    expect(itemSummary({ name: "temp" }, 0)).toBe("temp");
    expect(itemSummary({ server: "scada", coa: 1 }, 0)).toBe("server scada");
    expect(itemSummary({}, 2)).toBe("#3");
    expect(itemSummary(7, 0)).toBe("7");
  });
});
