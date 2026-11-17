// OIDs shown with their MIB names (numeric when no MIB knows them).
import { Link } from "react-router";
import type { OidInfo } from "../api/types";
import { enumLabel, normOid, oidLabel, useOidInfo, useOidInfos } from "./names";

export const browseLink = (oid: string) => `/mibs/browse?oid=${encodeURIComponent(normOid(oid))}`;

function title(oid: string, info: OidInfo | null | undefined): string {
  return info ? `${info.module}::${oidLabel(oid, info)}\n${normOid(oid)}` : normOid(oid);
}

/** One OID: its name (linked to the MIB browser) or the number. */
export function OidName({ oid, info, link = true, numeric = false }: { oid: string; info?: OidInfo | null; link?: boolean; numeric?: boolean }) {
  const fetched = useOidInfo(info === undefined ? oid : undefined);
  const i = info === undefined ? fetched : info;
  if (!i) return <span className="mono">{normOid(oid)}</span>;
  const label = oidLabel(oid, i);
  return (
    <span className="oid" title={title(oid, i)}>
      {link ? (
        <Link to={browseLink(i.base_oid)} className="mono">
          {label}
        </Link>
      ) : (
        <span className="mono">{label}</span>
      )}
      {numeric ? <span className="muted mono small"> {normOid(oid)}</span> : null}
    </span>
  );
}

/** A value with its enum label from the MIB (`up (1)`). */
export function ValueLabel({ info, value, text }: { info: OidInfo | null | undefined; value: unknown; text: string }) {
  const label = enumLabel(info, value);
  return label ? (
    <span title={text}>
      {label} <span className="muted">({text})</span>
    </span>
  ) : (
    <>{text}</>
  );
}

/** Varbinds as `name = value` lines (trace and trap lists). */
export function VarbindLines({ varbinds, format }: { varbinds: { oid: string }[]; format: (v: { oid: string }) => string }) {
  const lookup = useOidInfos(varbinds.map((v) => v.oid));
  return (
    <>
      {varbinds.map((v, i) => {
        const info = lookup(v.oid);
        const text = format(v);
        return (
          <div key={i}>
            <OidName oid={v.oid} info={info ?? null} link={false} /> ={" "}
            <ValueLabel info={info} value={(v as { value?: unknown }).value} text={text} />
          </div>
        );
      })}
    </>
  );
}
