import { useState, type ReactNode } from "react";
import { ApiError, formatSchemaError } from "../api/client";

export function Loading({ what }: { what?: string }) {
  return <div className="loading">Loading{what ? ` ${what}` : ""}…</div>;
}

export function ErrorBox({ error, title }: { error: unknown; title?: string }) {
  if (!error) return null;
  const msg = error instanceof Error ? error.message : String(error);
  const errors = error instanceof ApiError ? error.errors : [];
  return (
    <div className="alert error" role="alert">
      {title ? <strong>{title}: </strong> : null}
      {error instanceof ApiError && errors.length > 0 ? (
        <>
          {msg.split(":")[0]}
          <ul>
            {errors.map((e, i) => (
              <li key={i}>{formatSchemaError(e)}</li>
            ))}
          </ul>
        </>
      ) : (
        msg
      )}
    </div>
  );
}

export function Notice({ kind = "info", children }: { kind?: "info" | "warn" | "ok"; children: ReactNode }) {
  return <div className={`alert ${kind}`}>{children}</div>;
}

const HEALTH: Record<string, string> = {
  up: "ok",
  running: "ok",
  degraded: "warn",
  unknown: "muted",
  disabled: "muted",
  not_running: "muted",
  down: "bad",
  start_failed: "bad",
};

export function StateBadge({ state }: { state: string | undefined }) {
  const s = state ?? "unknown";
  return <span className={`badge ${HEALTH[s] ?? "muted"}`}>{s.replace(/_/g, " ")}</span>;
}

export function QualityBadges({ quality }: { quality: string[] | undefined }) {
  if (!quality || quality.length === 0) return <span className="badge ok">good</span>;
  return (
    <>
      {quality.map((q) => (
        <span key={q} className="badge bad">
          {q.replace(/_/g, " ")}
        </span>
      ))}
    </>
  );
}

/** A button that asks before it acts. */
export function ConfirmButton({
  onConfirm,
  children,
  question,
  className,
  disabled,
}: {
  onConfirm: () => void;
  children: ReactNode;
  question: string;
  className?: string;
  disabled?: boolean;
}) {
  const [asking, setAsking] = useState(false);
  if (!asking) {
    return (
      <button type="button" className={className} disabled={disabled} onClick={() => setAsking(true)}>
        {children}
      </button>
    );
  }
  return (
    <span className="confirm">
      <span>{question}</span>
      <button
        type="button"
        className="danger"
        onClick={() => {
          setAsking(false);
          onConfirm();
        }}
      >
        Yes
      </button>
      <button type="button" onClick={() => setAsking(false)}>
        No
      </button>
    </span>
  );
}

export function formatDate(ms: number | null | undefined): string {
  if (ms === null || ms === undefined) return "—";
  return new Date(ms).toLocaleString();
}

export function Tabs<T extends string>({
  tabs,
  value,
  onChange,
}: {
  tabs: { id: T; label: string }[];
  value: T;
  onChange: (t: T) => void;
}) {
  return (
    <div className="tabs" role="tablist">
      {tabs.map((t) => (
        <button
          key={t.id}
          type="button"
          role="tab"
          aria-selected={t.id === value}
          className={t.id === value ? "active" : undefined}
          onClick={() => onChange(t.id)}
        >
          {t.label}
        </button>
      ))}
    </div>
  );
}
