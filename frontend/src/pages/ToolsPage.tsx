import { useState, type FormEvent } from "react";
import { useSearchParams } from "react-router";
import { useSnmpGet, useSnmpWalk, useStatus } from "../api/hooks";
import type { Varbind } from "../api/types";
import { ErrorBox, Notice } from "../components/ui";
import { OidName, ValueLabel } from "../mib/Oid";
import { useOidInfos } from "../mib/names";

export function ToolsPage() {
  const [params, setParams] = useSearchParams();
  const status = useStatus(30000);
  const device = params.get("device") ?? "";
  const running = (status.data?.devices ?? []).filter((d) => d.health !== "disabled" && d.health !== "not_running");
  return (
    <div className="page">
      <h1>SNMP tools</h1>
      <p className="muted">
        Requests go through a running device of the active configuration, with its credentials, timeout and retries.
        They do not count for its health.
      </p>
      <label className="field">
        <span className="label">Device</span>
        <select
          value={device}
          onChange={(e) => setParams(e.target.value ? { device: e.target.value } : {})}
          aria-label="device"
        >
          <option value="">— choose —</option>
          {running.map((d) => (
            <option key={d.name} value={d.name}>
              {d.name} ({d.health})
            </option>
          ))}
          {device && !running.some((d) => d.name === device) ? <option value={device}>{device}</option> : null}
        </select>
      </label>
      {device ? (
        <div className="two-col">
          <GetTool device={device} />
          <WalkTool device={device} />
        </div>
      ) : null}
    </div>
  );
}

function GetTool({ device }: { device: string }) {
  const get = useSnmpGet();
  const [oids, setOids] = useState("1.3.6.1.2.1.1.1.0\n1.3.6.1.2.1.1.3.0\n1.3.6.1.2.1.1.5.0");
  const submit = (e: FormEvent) => {
    e.preventDefault();
    get.mutate({ device, oids: oids.split(/\s+/).filter(Boolean) });
  };
  return (
    <section className="card">
      <h2>GET</h2>
      <form onSubmit={submit}>
        <textarea rows={4} value={oids} onChange={(e) => setOids(e.target.value)} aria-label="OIDs" spellCheck={false} />
        <button type="submit" className="primary" disabled={get.isPending}>
          {get.isPending ? "Asking…" : "Get"}
        </button>
      </form>
      <ErrorBox error={get.error} />
      {get.data ? <Varbinds varbinds={get.data.varbinds} /> : null}
    </section>
  );
}

function WalkTool({ device }: { device: string }) {
  const walk = useSnmpWalk();
  const [oid, setOid] = useState("1.3.6.1.2.1.2.2.1.2");
  const [max, setMax] = useState(1000);
  const submit = (e: FormEvent) => {
    e.preventDefault();
    walk.mutate({ device, oid, max });
  };
  return (
    <section className="card">
      <h2>Walk</h2>
      <form className="inline" onSubmit={submit}>
        <input value={oid} onChange={(e) => setOid(e.target.value)} aria-label="root OID" spellCheck={false} />
        <input
          type="number"
          min={1}
          max={10000}
          value={max}
          onChange={(e) => setMax(Number(e.target.value))}
          aria-label="at most"
          className="short"
        />
        <button type="submit" className="primary" disabled={walk.isPending}>
          {walk.isPending ? "Walking…" : "Walk"}
        </button>
      </form>
      <ErrorBox error={walk.error} />
      {walk.data?.truncated ? <Notice kind="warn">Stopped after {max} varbinds.</Notice> : null}
      {walk.data ? <Varbinds varbinds={walk.data.varbinds} /> : null}
    </section>
  );
}

export function Varbinds({ varbinds }: { varbinds: Varbind[] }) {
  const lookup = useOidInfos(varbinds.map((v) => v.oid));
  if (varbinds.length === 0) return <p className="muted">No varbinds.</p>;
  return (
    <table className="compact">
      <thead>
        <tr>
          <th>OID</th>
          <th>Type</th>
          <th>Value</th>
        </tr>
      </thead>
      <tbody>
        {varbinds.map((v, i) => {
          const info = lookup(v.oid);
          return (
            <tr key={i}>
              <td>
                <OidName oid={v.oid} info={info ?? null} numeric />
              </td>
              <td>{v.type}</td>
              <td className="mono">
                {v.value === null ? (
                  <span title="binary">0x{v.hex}</span>
                ) : (
                  <ValueLabel info={info} value={v.value} text={String(v.value)} />
                )}
                {v.hex && v.value !== null ? <span className="muted"> (0x{v.hex})</span> : null}
              </td>
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}
