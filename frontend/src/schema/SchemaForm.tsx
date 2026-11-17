// Generic form for the entity schemas of the OpenAPI document (generated from
// s2i_schema): objects, discriminated unions, maps, arrays and scalars.
// Validation is the gateway's: its errors (path + code) are shown at the
// matching fields.
import { useEffect, useId, useState } from "react";
import type { SchemaError } from "../api/client";
import {
  errorsAt,
  hasErrorsUnder,
  initialValue,
  isEnvelope,
  isMap,
  isObject,
  isUnion,
  itemSummary,
  label,
  orderedKeys,
  setIn,
  switchVariant,
  variantOf,
  variants,
} from "./logic";
import type { JsonSchema, Path } from "./types";
import { OidHint } from "../mib/OidHint";

interface FieldProps {
  schema: JsonSchema;
  value: unknown;
  onChange: (v: unknown) => void;
  path: Path;
  errors: SchemaError[];
  required?: boolean;
  /** Top-level fields shown but not editable (the name of an existing entity). */
  locked?: string[];
  /** id of the scalar control, for its <label htmlFor>. */
  id?: string;
}

export interface SchemaFormProps {
  schema: JsonSchema;
  value: unknown;
  onChange: (v: unknown) => void;
  errors: SchemaError[];
  readOnly?: boolean;
  locked?: string[];
}

export function SchemaForm({ schema, value, onChange, errors, readOnly = false, locked = [] }: SchemaFormProps) {
  return (
    <fieldset className="schema-form" disabled={readOnly}>
      <SchemaField schema={schema} value={value} onChange={onChange} path={[]} errors={errors} required locked={locked} />
    </fieldset>
  );
}

function SchemaField(p: FieldProps) {
  const s = p.schema;
  if (isUnion(s)) return <UnionField {...p} />;
  if (s.oneOf) return <ScalarChoice {...p} />;
  if (isMap(s)) return <MapField {...p} />;
  if (s.type === "object") return <ObjectField {...p} />;
  if (s.type === "array") return isComposite(s.items ?? {}) ? <ArrayField {...p} /> : <ListField {...p} />;
  return <Scalar {...p} />;
}

const isComposite = (s: JsonSchema): boolean =>
  isUnion(s) || isMap(s) || s.type === "object" || (s.type === "array" && isComposite(s.items ?? {}));

function Errors({ errors }: { errors: SchemaError[] }) {
  if (errors.length === 0) return null;
  return (
    <ul className="field-errors">
      {errors.map((e, i) => (
        <li key={i}>
          {e.error.replace(/_/g, " ")}
          {e.detail ? ` ${JSON.stringify(e.detail)}` : ""}
        </li>
      ))}
    </ul>
  );
}

// --- objects -------------------------------------------------------------------

function ObjectField({ schema, value, onChange, path, errors, locked, exclude = [] }: FieldProps & { exclude?: string[] }) {
  const obj = isObject(value) ? value : {};
  return (
    <div className="fields">
      <Errors errors={errorsAt(errors, path)} />
      {orderedKeys(schema)
        .filter((k) => !exclude.includes(k))
        .map((k) => (
          <Property
            key={k}
            name={k}
            schema={schema.properties![k]}
            required={schema.required?.includes(k) ?? false}
            value={obj[k]}
            onChange={(v) => onChange(setIn(obj, [k], v))}
            path={[...path, k]}
            errors={errors}
            locked={path.length === 0 && (locked ?? []).includes(k)}
          />
        ))}
    </div>
  );
}

interface PropertyProps extends Omit<FieldProps, "locked"> {
  name: string;
  locked: boolean;
}

function Property({ name, schema, required, value, onChange, path, errors, locked }: PropertyProps) {
  const id = useId();
  const title = (
    <>
      {label(name)}
      {required ? <span className="req"> *</span> : null}
    </>
  );
  const desc = schema.description ? <small className="hint">{schema.description}</small> : null;
  if (locked) {
    return (
      <div className="field">
        <span className="label">{title}</span>
        <span className="locked">{String(value ?? "")}</span>
      </div>
    );
  }
  if (isComposite(schema)) {
    if (value === undefined && !required) {
      return (
        <div className="field absent">
          <span className="label">{title}</span>
          <button type="button" className="small" onClick={() => onChange(initialValue(schema))}>
            Add
          </button>
          {desc}
        </div>
      );
    }
    return (
      <fieldset className="group">
        <legend>
          {title}
          {!required ? (
            <button type="button" className="link small" onClick={() => onChange(undefined)}>
              remove
            </button>
          ) : null}
        </legend>
        {desc}
        <SchemaField schema={schema} value={value} onChange={onChange} path={path} errors={errors} required={required} />
      </fieldset>
    );
  }
  return (
    <div className="field">
      <label className="label" htmlFor={id}>
        {title}
      </label>
      <span className="control">
        <SchemaField schema={schema} value={value} onChange={onChange} path={path} errors={errors} required={required} id={id} />
        {desc}
        <Errors errors={errorsAt(errors, path)} />
      </span>
    </div>
  );
}

function UnionField(p: FieldProps) {
  const { schema, value, onChange, path, errors } = p;
  const tag = schema.discriminator!.propertyName;
  const vs = variants(schema);
  const current = variantOf(schema, value);
  const tagValue = isObject(value) ? value[tag] : undefined;
  const id = useId();
  return (
    <div className="fields">
      <div className="field">
        <label className="label" htmlFor={id}>
          {label(tag)}
          <span className="req"> *</span>
        </label>
        <span className="control">
          <select
            id={id}
            value={tagValue === undefined ? "" : String(tagValue)}
            onChange={(e) => {
              const v = vs.find((x) => String(x.value) === e.target.value);
              if (v) onChange(switchVariant(schema, value, v.value));
            }}
          >
            {current ? null : <option value="">—</option>}
            {vs.map((v) => (
              <option key={String(v.value)} value={String(v.value)}>
                {String(v.value)}
              </option>
            ))}
          </select>
          <Errors errors={errorsAt(errors, [...path, tag])} />
        </span>
      </div>
      {current ? <ObjectField {...p} schema={current} exclude={[tag]} /> : <Errors errors={errorsAt(errors, path)} />}
    </div>
  );
}

// --- maps -----------------------------------------------------------------------

function MapField({ schema, value, onChange, path, errors }: FieldProps) {
  const obj = isObject(value) ? value : {};
  const valueSchema = schema.additionalProperties as JsonSchema;
  const [newKey, setNewKey] = useState("");
  const keyPattern = schema.propertyNames?.pattern;
  const keyOk = newKey !== "" && !(newKey in obj) && (!keyPattern || new RegExp(keyPattern).test(newKey));
  const rename = (from: string, to: string) => {
    if (to === from || to === "" || to in obj) return;
    onChange(Object.fromEntries(Object.entries(obj).map(([k, v]) => [k === from ? to : k, v])));
  };
  return (
    <div className="map">
      <Errors errors={errorsAt(errors, path)} />
      {Object.entries(obj).map(([k, v]) => (
        <div key={k} className="map-row">
          <KeyInput value={k} onCommit={(to) => rename(k, to)} />
          <div className="map-value">
            <SchemaField
              schema={valueSchema}
              value={v}
              onChange={(nv) => onChange(setIn(obj, [k], nv))}
              path={[...path, k]}
              errors={errors}
              required
            />
            {isComposite(valueSchema) ? null : <Errors errors={errorsAt(errors, [...path, k])} />}
          </div>
          <button
            type="button"
            className="link small"
            onClick={() => onChange(Object.fromEntries(Object.entries(obj).filter(([x]) => x !== k)))}
          >
            remove
          </button>
        </div>
      ))}
      <div className="map-add">
        <input
          placeholder="new key"
          value={newKey}
          onChange={(e) => setNewKey(e.target.value)}
          aria-label="new key"
        />
        <button
          type="button"
          className="small"
          disabled={!keyOk}
          onClick={() => {
            onChange({ ...obj, [newKey]: initialValue(valueSchema) });
            setNewKey("");
          }}
        >
          Add
        </button>
      </div>
    </div>
  );
}

function KeyInput({ value, onCommit }: { value: string; onCommit: (v: string) => void }) {
  const [text, setText] = useState(value);
  useEffect(() => setText(value), [value]);
  return (
    <input
      className="map-key"
      value={text}
      aria-label="key"
      onChange={(e) => setText(e.target.value)}
      onBlur={() => (text === value ? undefined : onCommit(text))}
    />
  );
}

// --- arrays -----------------------------------------------------------------------

function ArrayField({ schema, value, onChange, path, errors }: FieldProps) {
  const items = Array.isArray(value) ? value : [];
  const itemSchema = schema.items ?? {};
  const move = (i: number, d: number) => {
    const next = [...items];
    [next[i], next[i + d]] = [next[i + d], next[i]];
    onChange(next);
  };
  return (
    <div className="array">
      <Errors errors={errorsAt(errors, path)} />
      {items.map((item, i) => (
        <details key={i} className="item" open={items.length <= 3 || hasErrorsUnder(errors, [...path, i])}>
          <summary>
            <span className="item-title">{itemSummary(item, i)}</span>
            <span className="item-actions">
              <button type="button" className="link small" disabled={i === 0} onClick={() => move(i, -1)} title="move up">
                ↑
              </button>
              <button
                type="button"
                className="link small"
                disabled={i === items.length - 1}
                onClick={() => move(i, 1)}
                title="move down"
              >
                ↓
              </button>
              <button type="button" className="link small" onClick={() => onChange(items.filter((_, j) => j !== i))}>
                remove
              </button>
            </span>
          </summary>
          <SchemaField
            schema={itemSchema}
            value={item}
            onChange={(v) => onChange(items.map((x, j) => (j === i ? v : x)))}
            path={[...path, i]}
            errors={errors}
            required
          />
        </details>
      ))}
      <button type="button" className="small" onClick={() => onChange([...items, initialValue(itemSchema)])}>
        Add {schema.items?.type === "object" || isUnion(itemSchema) ? "item" : ""}
      </button>
    </div>
  );
}

/** Arrays of scalars as one comma-separated input. */
function ListField({ schema, value, onChange, path, errors, id }: FieldProps) {
  const items = Array.isArray(value) ? value : [];
  const shown = items.map(String).join(", ");
  const [text, setText] = useState(shown);
  useEffect(() => setText(shown), [shown]);
  const numeric = schema.items?.type === "integer" || schema.items?.type === "number";
  const commit = () => {
    const parts = text
      .split(/[,\s]+/)
      .map((x) => x.trim())
      .filter((x) => x !== "");
    onChange(parts.map((x) => (numeric && /^-?\d+(\.\d+)?$/.test(x) ? Number(x) : x)));
  };
  const itemErrors = errors.filter(
    (e) => e.path.length === path.length + 1 && path.every((p, i) => e.path[i] === p),
  );
  return (
    <>
      <input
        id={id}
        value={text}
        placeholder={numeric ? "e.g. 1, 2, 3" : "comma-separated"}
        onChange={(e) => setText(e.target.value)}
        onBlur={commit}
      />
      <Errors errors={itemErrors.map((e) => ({ ...e, error: `item ${Number(e.path[path.length]) + 1}: ${e.error}` }))} />
    </>
  );
}

// --- scalars ------------------------------------------------------------------------

function Scalar({ schema, value, onChange, required, id }: FieldProps) {
  if (schema.const !== undefined) return <span className="locked">{String(schema.const)}</span>;
  if (schema.enum) {
    return (
      <select
        id={id}
        value={value === undefined ? "" : String(value)}
        onChange={(e) => onChange(e.target.value === "" ? undefined : e.target.value)}
      >
        {!required || value === undefined ? (
          <option value="">{schema.default !== undefined ? `(default: ${String(schema.default)})` : "—"}</option>
        ) : null}
        {schema.enum.map((v) => (
          <option key={String(v)} value={String(v)}>
            {String(v)}
          </option>
        ))}
      </select>
    );
  }
  switch (schema.type) {
    case "boolean":
      return (
        <input
          id={id}
          type="checkbox"
          checked={(value ?? schema.default ?? false) === true}
          onChange={(e) => onChange(e.target.checked)}
        />
      );
    case "integer":
    case "number":
      return (
        <input
          id={id}
          type="number"
          value={typeof value === "number" ? value : value === undefined ? "" : String(value)}
          min={schema.minimum}
          max={schema.maximum}
          step={schema.type === "integer" ? 1 : "any"}
          placeholder={schema.default !== undefined ? String(schema.default) : undefined}
          onChange={(e) => onChange(e.target.value === "" ? undefined : Number(e.target.value))}
        />
      );
    case "string":
      if (schema.writeOnly) return <SecretInput id={id} value={value} onChange={onChange} required={required} />;
      if (schema.format === "oid" || schema.format === "oid-template")
        return <OidInput id={id} value={value} onChange={onChange} required={required} template={schema.format === "oid-template"} />;
      return (
        <input
          id={id}
          value={typeof value === "string" ? value : value === undefined ? "" : String(value)}
          placeholder={schema.default !== undefined ? String(schema.default) : undefined}
          maxLength={schema.maxLength}
          onChange={(e) => onChange(e.target.value === "" && !required ? undefined : e.target.value)}
        />
      );
    default:
      return <RawJson id={id} value={value} onChange={onChange} />;
  }
}

/**
 * Secrets are read back as `enc:v1:` envelopes: sending the envelope back
 * keeps the stored secret, a plaintext replaces it.
 */
function SecretInput({
  id,
  value,
  onChange,
  required,
}: {
  id?: string;
  value: unknown;
  onChange: (v: unknown) => void;
  required?: boolean;
}) {
  const [stored] = useState(isEnvelope(value) ? value : undefined);
  if (isEnvelope(value)) {
    return (
      <span className="secret">
        <span className="badge">stored, encrypted</span>
        <button type="button" className="small" onClick={() => onChange("")}>
          Change
        </button>
      </span>
    );
  }
  return (
    <span className="secret">
      <input
        id={id}
        type="password"
        autoComplete="new-password"
        value={typeof value === "string" ? value : ""}
        onChange={(e) => onChange(e.target.value === "" && !required ? undefined : e.target.value)}
      />
      {stored !== undefined ? (
        <button type="button" className="link small" onClick={() => onChange(stored)}>
          keep stored
        </button>
      ) : null}
    </span>
  );
}

/**
 * `oneOf` of scalars (SNMP constants: integer or text; enum states:
 * boolean, state name or integer): one text input, typed on input.
 */
export function parseChoice(schema: JsonSchema, text: string): unknown {
  const opts = schema.oneOf ?? [];
  const t = text.trim();
  if (opts.some((o) => o.type === "boolean") && (t === "true" || t === "false")) return t === "true";
  const en = opts.find((o) => o.enum?.includes(t));
  if (en) return t;
  if (opts.some((o) => o.type === "integer") && /^-?\d+$/.test(t)) return Number(t);
  if (opts.some((o) => o.type === "number") && t !== "" && !Number.isNaN(Number(t))) return Number(t);
  return text;
}

function ScalarChoice({ schema, value, onChange, id }: FieldProps) {
  const shown = value === undefined ? "" : String(value);
  const [text, setText] = useState(shown);
  useEffect(() => setText(shown), [shown]);
  const hint = (schema.oneOf ?? [])
    .map((o) => (o.enum ? o.enum.join(" | ") : o.type))
    .filter(Boolean)
    .join(" or ");
  return (
    <input
      id={id}
      value={text}
      placeholder={hint}
      title={hint}
      onChange={(e) => setText(e.target.value)}
      onBlur={() => onChange(text === "" ? undefined : parseChoice(schema, text))}
    />
  );
}

function RawJson({ id, value, onChange }: { id?: string; value: unknown; onChange: (v: unknown) => void }) {
  const shown = value === undefined ? "" : JSON.stringify(value);
  const [text, setText] = useState(shown);
  const [bad, setBad] = useState(false);
  useEffect(() => setText(shown), [shown]);
  return (
    <input
      id={id}
      className={bad ? "invalid" : undefined}
      value={text}
      placeholder="JSON"
      onChange={(e) => setText(e.target.value)}
      onBlur={() => {
        if (text === "") return onChange(undefined);
        try {
          onChange(JSON.parse(text));
          setBad(false);
        } catch {
          setBad(true);
        }
      }}
    />
  );
}

/**
 * Numeric OID with its MIB name below; a name typed instead
 * (`ifOperStatus`, `IF-MIB::ifOperStatus.0`) can be turned into the number.
 */
function OidInput({
  id,
  value,
  onChange,
  required,
  template,
}: {
  id?: string;
  value: unknown;
  onChange: (v: unknown) => void;
  required?: boolean;
  template: boolean;
}) {
  const text = typeof value === "string" ? value : value === undefined ? "" : String(value);
  return (
    <span className="oid-input">
      <input
        id={id}
        value={text}
        spellCheck={false}
        placeholder={template ? "1.3.6.1.2.1.2.2.1.8.{index} or a MIB name" : "numeric OID or a MIB name"}
        onChange={(e) => onChange(e.target.value === "" && !required ? undefined : e.target.value)}
      />
      <OidHint text={text} template={template} onUse={(oid) => onChange(oid)} />
    </span>
  );
}
