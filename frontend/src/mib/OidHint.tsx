// The MIB name under an OID field, or the number for a name typed into it.
import { useEffect, useState } from "react";
import { oidLabel, useOidInfo, useResolvedName } from "./names";

const NUMERIC = /^\.?\d+(\.\d+)+$/;
const TEMPLATE_SUFFIX = ".{index}";

/** The input after a short pause, so typing does not query every keystroke. */
function useSettled(text: string, ms = 400): string {
  const [settled, setSettled] = useState(text);
  useEffect(() => {
    const t = setTimeout(() => setSettled(text), ms);
    return () => clearTimeout(t);
  }, [text, ms]);
  return settled;
}

export function OidHint({ text, template, onUse }: { text: string; template: boolean; onUse: (oid: string) => void }) {
  const t = useSettled(text.trim());
  const base = template && t.endsWith(TEMPLATE_SUFFIX) ? t.slice(0, -TEMPLATE_SUFFIX.length) : t;
  const numeric = NUMERIC.test(base);
  const info = useOidInfo(numeric ? base : undefined);
  const named = !numeric && /^[A-Za-z][\w-]*(::[A-Za-z][\w-]*)?(\.\d+)*$/.test(base) ? base : undefined;
  const resolved = useResolvedName(named);
  const target = useOidInfo(resolved?.oid);
  if (numeric) {
    if (!info) return null;
    const label = oidLabel(base, info);
    return (
      <span className="hint">
        <span className="mono">
          {info.module}::{label}
          {base !== t ? TEMPLATE_SUFFIX : ""}
        </span>
        {info.syntax ? <span className="muted"> · {info.syntax}</span> : null}
        {info.units ? <span className="muted"> · {info.units}</span> : null}
        {info.enums?.length ? (
          <span className="muted"> · {info.enums.map((e) => `${e.value} ${e.name}`).join(", ")}</span>
        ) : null}
      </span>
    );
  }
  if (!named || !resolved) return null;
  if (!resolved.oid) {
    const why =
      resolved.error === "ambiguous"
        ? `ambiguous, defined in ${(resolved.modules ?? []).join(", ")}: write MODULE::name`
        : "unknown name (upload its MIB, or enter the numeric OID)";
    return <span className="hint muted">{why}</span>;
  }
  // a bare object name: scalars are polled as .0, table columns per instance
  const bare = !/\.\d+$/.test(named);
  const oid =
    bare && target?.kind === "scalar"
      ? `${resolved.oid}.0`
      : bare && template && target?.kind === "column"
        ? `${resolved.oid}${TEMPLATE_SUFFIX}`
        : resolved.oid;
  return (
    <span className="hint">
      <button type="button" className="link small" onClick={() => onUse(oid)}>
        use {oid}
      </button>
    </span>
  );
}
