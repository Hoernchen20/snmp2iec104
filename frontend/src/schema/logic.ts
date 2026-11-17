// Pure helpers of the schema-driven entity form.
import type { SchemaError } from "../api/client";
import type { JsonSchema, Path } from "./types";

export type Value = unknown;
type Obj = Record<string, unknown>;

export const isObject = (v: unknown): v is Obj => typeof v === "object" && v !== null && !Array.isArray(v);

/** Stored secrets come back as AES-GCM envelopes (docs/DESIGN.md §5.7a). */
export const isEnvelope = (v: unknown): boolean => typeof v === "string" && v.startsWith("enc:v1:");

export function orderedKeys(schema: JsonSchema): string[] {
  const props = Object.keys(schema.properties ?? {});
  const order = schema["x-order"] ?? [];
  return [...order.filter((k) => props.includes(k)), ...props.filter((k) => !order.includes(k))];
}

/** A map (`map_of`): an object whose keys are data, not fields. */
export const isMap = (s: JsonSchema): boolean =>
  s.type === "object" && !s.properties && isObject(s.additionalProperties);

/** A discriminated union (`union`): `oneOf` + `discriminator`. */
export const isUnion = (s: JsonSchema): boolean => !!s.oneOf && !!s.discriminator;

export function variants(s: JsonSchema): { tag: string; value: string | number; schema: JsonSchema }[] {
  const tag = s.discriminator!.propertyName;
  return (s.oneOf ?? []).map((v) => ({ tag, value: v.properties?.[tag]?.const as string | number, schema: v }));
}

export function variantOf(s: JsonSchema, value: Value): JsonSchema | undefined {
  if (!isObject(value)) return undefined;
  const tag = s.discriminator!.propertyName;
  return (s.oneOf ?? []).find((v) => v.properties?.[tag]?.const === value[tag]);
}

const clone = <T>(v: T): T => (v === undefined ? v : JSON.parse(JSON.stringify(v)));

/**
 * A fresh value for `schema`: defaults and constants, required fields only.
 * Required strings start empty; numbers without default stay unset.
 */
export function initialValue(schema: JsonSchema): Value {
  if (schema.const !== undefined) return schema.const;
  if (schema.default !== undefined) return clone(schema.default);
  if (isUnion(schema)) return initialValue(schema.oneOf![0]);
  switch (schema.type) {
    case "object": {
      if (!schema.properties) return {};
      const out: Obj = {};
      for (const k of orderedKeys(schema)) {
        if (!schema.required?.includes(k)) continue;
        const v = initialValue(schema.properties[k]);
        if (v !== undefined) out[k] = v;
      }
      return out;
    }
    case "array":
      return [];
    case "string":
      return schema.enum ? schema.enum[0] : "";
    case "boolean":
      return false;
    default:
      return undefined;
  }
}

/** Switch a union value to another variant, keeping the fields both share. */
export function switchVariant(s: JsonSchema, value: Value, tagValue: string | number): Value {
  const target = (s.oneOf ?? []).find((v) => v.properties?.[s.discriminator!.propertyName]?.const === tagValue);
  if (!target) return value;
  const fresh = initialValue(target) as Obj;
  if (!isObject(value)) return fresh;
  const tag = s.discriminator!.propertyName;
  for (const [k, v] of Object.entries(value)) {
    if (k !== tag && target.properties && k in target.properties) fresh[k] = v;
  }
  return fresh;
}

/** Immutable update; `undefined` removes an object key. */
export function setIn(root: Value, path: Path, value: Value): Value {
  if (path.length === 0) return value;
  const [head, ...rest] = path;
  if (typeof head === "number") {
    const arr = Array.isArray(root) ? [...root] : [];
    arr[head] = setIn(arr[head], rest, value);
    return arr;
  }
  const obj: Obj = isObject(root) ? { ...root } : {};
  const next = setIn(obj[head], rest, value);
  if (next === undefined) delete obj[head];
  else obj[head] = next;
  return obj;
}

export function getIn(root: Value, path: Path): Value {
  let cur: unknown = root;
  for (const p of path) {
    if (cur === null || cur === undefined) return undefined;
    cur = (cur as Record<string | number, unknown>)[p];
  }
  return cur;
}

const samePath = (a: Path, b: Path) => a.length === b.length && a.every((p, i) => p === b[i]);

/** Errors reported exactly at `path`. */
export const errorsAt = (errors: SchemaError[], path: Path): SchemaError[] =>
  errors.filter((e) => samePath(e.path, path));

/** Whether any error lies at or below `path` (to open collapsed sections). */
export const hasErrorsUnder = (errors: SchemaError[], path: Path): boolean =>
  errors.some((e) => e.path.length >= path.length && path.every((p, i) => e.path[i] === p));

/** `common_addresses` → `Common addresses`. */
export function label(key: string): string {
  const s = key.replace(/_/g, " ");
  return s.charAt(0).toUpperCase() + s.slice(1);
}

/** Short summary of an array item for its collapsed header. */
export function itemSummary(item: Value, index: number): string {
  if (isObject(item)) {
    for (const k of ["name", "datapoint", "server", "slot", "oid", "kind", "version"]) {
      const v = item[k];
      if (typeof v === "string" || typeof v === "number") return `${k === "name" ? "" : k + " "}${v}`;
    }
  } else if (item !== undefined && item !== null && typeof item !== "object") {
    return String(item);
  }
  return `#${index + 1}`;
}
