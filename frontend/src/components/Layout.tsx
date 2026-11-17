import type { ReactNode } from "react";
import { Link, NavLink } from "react-router";
import { useLogout, useStatus } from "../api/hooks";
import type { Me } from "../api/types";

export function Layout({ me, children }: { me: Me; children: ReactNode }) {
  const logout = useLogout();
  const status = useStatus();
  const nav: [string, string][] = [
    ["/", "Status"],
    ["/devices", "Devices"],
    ["/profiles", "Profiles"],
    ["/servers", "IEC servers"],
    ["/config", "Configuration"],
    ["/debug", "Live debug"],
    ["/tools", "SNMP tools"],
    ...(me.role === "admin" ? ([["/users", "Users"]] as [string, string][]) : []),
  ];
  return (
    <div className="app">
      <header className="topbar">
        <Link to="/" className="brand">
          snmp2iec104
        </Link>
        <nav>
          {nav.map(([to, label]) => (
            <NavLink key={to} to={to} end={to === "/"}>
              {label}
            </NavLink>
          ))}
        </nav>
        <div className="user">
          <NavLink to="/account" title="Account">
            {me.name} <span className="role">{me.role}</span>
          </NavLink>
          <button type="button" className="link" onClick={() => logout.mutate()}>
            Log out
          </button>
        </div>
      </header>
      {status.data?.has_changes ? (
        <div className="banner">
          The staged configuration has changes that are not active yet. <Link to="/config">Review and activate</Link>
        </div>
      ) : null}
      <main>{children}</main>
    </div>
  );
}
