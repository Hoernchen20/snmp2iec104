import { useState } from "react";
import { Link, useNavigate } from "react-router";
import { useEntities, useStatus } from "../api/hooks";
import { LABEL, type Device, type EntityKind, type Profile, type Server } from "../api/types";
import { ErrorBox, Loading, StateBadge } from "../components/ui";

const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/;

export function EntityList({ kind, admin }: { kind: EntityKind; admin: boolean }) {
  const list = useEntities(kind);
  const status = useStatus();
  const navigate = useNavigate();
  const [filter, setFilter] = useState("");
  const [newName, setNewName] = useState("");
  if (list.isPending) return <Loading />;
  if (list.isError) return <ErrorBox error={list.error} />;
  const health = new Map<string, string>([
    ...(status.data?.devices ?? []).map((d) => [d.name, d.health] as [string, string]),
    ...(status.data?.servers ?? []).map((s) => [s.name, s.state] as [string, string]),
  ]);
  const f = filter.toLowerCase();
  const rows = (list.data as (Server | Device | Profile)[]).filter(
    (e) => !f || e.name.toLowerCase().includes(f) || (e.description ?? "").toLowerCase().includes(f),
  );
  const exists = (list.data as { name: string }[]).some((e) => e.name === newName);
  return (
    <div className="page">
      <h1>{LABEL[kind].many}</h1>
      <p className="muted">
        The staged configuration. Changes take effect when the configuration is <Link to="/config">activated</Link>.
      </p>
      <div className="toolbar">
        <input placeholder="Filter" value={filter} onChange={(e) => setFilter(e.target.value)} aria-label="filter" />
        {admin ? (
          <form
            className="inline"
            onSubmit={(e) => {
              e.preventDefault();
              navigate(`/${kind}/${encodeURIComponent(newName)}?new=1`);
            }}
          >
            <input placeholder="New name" value={newName} onChange={(e) => setNewName(e.target.value)} aria-label="new name" />
            <button type="submit" className="primary" disabled={!NAME_RE.test(newName) || exists}>
              New {LABEL[kind].one.toLowerCase()}
            </button>
          </form>
        ) : null}
      </div>
      {rows.length === 0 ? (
        <p className="muted">{list.data.length === 0 ? `No ${LABEL[kind].many.toLowerCase()} yet.` : "Nothing matches."}</p>
      ) : (
        <table>
          <thead>
            <tr>
              <th>Name</th>
              {columns(kind).map((c) => (
                <th key={c.title}>{c.title}</th>
              ))}
              <th>Description</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((e) => (
              <tr key={e.name}>
                <td>
                  <Link to={`/${kind}/${encodeURIComponent(e.name)}`}>{e.name}</Link>
                </td>
                {columns(kind).map((c) => (
                  <td key={c.title}>{c.cell(e, health.get(e.name))}</td>
                ))}
                <td className="muted">{e.description}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}

interface Column {
  title: string;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  cell: (e: any, state: string | undefined) => React.ReactNode;
}

function columns(kind: EntityKind): Column[] {
  switch (kind) {
    case "devices":
      return [
        { title: "Address", cell: (d: Device) => `${d.host}:${d.port}` },
        { title: "SNMP", cell: (d: Device) => d.snmp.version },
        { title: "Profile", cell: (d: Device) => <Link to={`/profiles/${encodeURIComponent(d.profile)}`}>{d.profile}</Link> },
        { title: "IOA base", cell: (d: Device) => d.ioa_base },
        {
          title: "State",
          cell: (d: Device, s) => (d.enabled ? <StateBadge state={s ?? "not active"} /> : <StateBadge state="disabled" />),
        },
      ];
    case "servers":
      return [
        { title: "Transport", cell: (s: Server) => `${s.transport.kind} ${s.transport.ip}:${s.transport.port}` },
        { title: "COAs", cell: (s: Server) => s.common_addresses.join(", ") },
        { title: "Redundancy", cell: (s: Server) => s.redundancy?.mode ?? "connection" },
        { title: "State", cell: (_s: Server, st) => <StateBadge state={st ?? "not active"} /> },
      ];
    case "profiles":
      return [
        { title: "Datapoints", cell: (p: Profile) => p.datapoints?.length ?? 0 },
        { title: "Trap rules", cell: (p: Profile) => p.trap_rules?.length ?? 0 },
        { title: "Poll groups", cell: (p: Profile) => Object.entries(p.poll_groups ?? {}).map(([g, ms]) => `${g} ${ms / 1000}s`).join(", ") },
      ];
  }
}
