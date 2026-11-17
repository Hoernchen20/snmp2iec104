import { Link } from "react-router";
import { useStatus } from "../api/hooks";
import type { DeviceStatus } from "../api/types";
import { ErrorBox, Loading, StateBadge, formatDate } from "../components/ui";

export function StatusPage() {
  const status = useStatus();
  if (status.isPending) return <Loading what="status" />;
  if (status.isError) return <ErrorBox error={status.error} />;
  const { devices, servers, active_vsn } = status.data;
  const counts = devices.reduce<Record<string, number>>((acc, d) => {
    acc[d.health] = (acc[d.health] ?? 0) + 1;
    return acc;
  }, {});
  return (
    <div className="page">
      <h1>Status</h1>
      <p className="muted">
        Active configuration: {active_vsn === null ? "none yet" : <Link to="/config">version {active_vsn}</Link>}
        {" · "}
        {devices.length} devices
        {Object.entries(counts).map(([h, n]) => (
          <span key={h}>
            {" "}
            <StateBadge state={h} /> {n}
          </span>
        ))}
      </p>

      <h2>IEC 104 servers</h2>
      {servers.length === 0 ? (
        <p className="muted">No servers in the active configuration.</p>
      ) : (
        <table>
          <thead>
            <tr>
              <th>Server</th>
              <th>State</th>
              <th className="num">Points</th>
              <th>Redundancy groups</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {servers.map((s) => (
              <tr key={s.name}>
                <td>
                  <Link to={`/servers/${encodeURIComponent(s.name)}`}>{s.name}</Link>
                </td>
                <td>
                  <StateBadge state={s.state} />
                </td>
                <td className="num">{s.points}</td>
                <td>
                  {s.groups.length === 0 ? (
                    <span className="muted">no connection</span>
                  ) : (
                    s.groups.map((g, i) => (
                      <span key={i} className="group-chip" title={`${g.members} connection(s), ${g.buffer_len} unacknowledged`}>
                        {g.name}: {g.active ? "active" : "no active connection"} ({g.members})
                        {g.buffer_len > 0 ? `, buffer ${g.buffer_len}` : ""}
                      </span>
                    ))
                  )}
                </td>
                <td className="actions">
                  <Link to={`/debug?view=server&name=${encodeURIComponent(s.name)}`}>live values</Link>
                  <Link to={`/debug?view=iec&name=${encodeURIComponent(s.name)}`}>connections</Link>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      <h2>Devices</h2>
      {devices.length === 0 ? (
        <p className="muted">
          No devices in the active configuration. <Link to="/devices">Add devices</Link>, then activate the
          configuration.
        </p>
      ) : (
        <table>
          <thead>
            <tr>
              <th>Device</th>
              <th>Health</th>
              <th className="num">Poll cycles</th>
              <th className="num">Failures</th>
              <th className="num">Overruns</th>
              <th>Last good poll</th>
              <th className="num">Traps (unmatched)</th>
              <th>Instances</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {devices.map((d) => (
              <DeviceRow key={d.name} d={d} />
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}

function DeviceRow({ d }: { d: DeviceStatus }) {
  const unresolved = d.unresolved ?? [];
  const n = encodeURIComponent(d.name);
  return (
    <tr>
      <td>
        <Link to={`/devices/${n}`}>{d.name}</Link>
        {d.error ? <div className="small error-text">{String(JSON.stringify(d.error))}</div> : null}
      </td>
      <td>
        <StateBadge state={d.health} />
        {d.registered === false && d.health !== "disabled" ? <span className="badge warn">not registered</span> : null}
      </td>
      <td className="num">{d.cycles ?? ""}</td>
      <td className="num">{d.failures ?? ""}</td>
      <td className="num">{d.overruns ?? ""}</td>
      <td>{typeof d.last_ok === "number" ? formatDate(d.last_ok) : "—"}</td>
      <td className="num">{d.traps !== undefined ? `${d.traps} (${d.unmatched ?? 0})` : ""}</td>
      <td>
        {unresolved.length > 0 ? (
          <span className="badge warn" title={unresolved.join("\n")}>
            {unresolved.length} unresolved
          </span>
        ) : d.health === "disabled" || d.health === "not_running" ? null : (
          <span className="muted">ok</span>
        )}
      </td>
      <td className="actions">
        <Link to={`/debug?view=device&name=${n}`}>live values</Link>
        <Link to={`/debug?view=trace&name=${n}`}>trace</Link>
        <Link to={`/tools?device=${n}`}>tools</Link>
      </td>
    </tr>
  );
}
