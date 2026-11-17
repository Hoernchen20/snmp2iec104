import { useRef, useState } from "react";
import { Link } from "react-router";
import { formatSchemaError, get } from "../api/client";
import {
  useActivate,
  useActive,
  useAudit,
  useImport,
  useRestore,
  useRevert,
  useStaged,
  useValidate,
  useVersions,
} from "../api/hooks";
import type { Config } from "../api/types";
import { ConfirmButton, ErrorBox, Loading, Notice, formatDate } from "../components/ui";
import { diffConfigs } from "../lib/configDiff";

function download(name: string, data: unknown) {
  const url = URL.createObjectURL(new Blob([JSON.stringify(data, null, 2)], { type: "application/json" }));
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  a.click();
  URL.revokeObjectURL(url);
}

export function ConfigPage({ admin }: { admin: boolean }) {
  return (
    <div className="page">
      <h1>Configuration</h1>
      <StagedSection admin={admin} />
      <VersionsSection admin={admin} />
      <BackupSection admin={admin} />
      <AuditSection />
    </div>
  );
}

function StagedSection({ admin }: { admin: boolean }) {
  const staged = useStaged();
  const active = useActive();
  const validate = useValidate();
  const activate = useActivate();
  const revert = useRevert();
  const [comment, setComment] = useState("");
  if (staged.isPending || active.isPending) return <Loading what="configuration" />;
  if (staged.isError) return <ErrorBox error={staged.error} />;
  if (active.isError) return <ErrorBox error={active.error} />;
  const changes = diffConfigs(staged.data.config, active.data?.config ?? null);
  const v = validate.data;
  const restarts = v?.server_restarts ?? [];
  const doActivate = () =>
    activate.mutate(comment, {
      onSuccess: () => {
        setComment("");
        validate.reset();
      },
    });
  return (
    <section className="card">
      <h2>Staged changes</h2>
      <p className="muted">
        Active: {active.data ? `version ${active.data.vsn}` : "nothing activated yet"}. Edits go to the staged
        configuration; activating validates it and applies it as a new version.
      </p>
      {changes.length === 0 ? (
        <p>No changes against the active configuration.</p>
      ) : (
        <ul className="changes">
          {changes.map((c) => (
            <li key={`${c.kind}/${c.name}`}>
              <span className={`badge ${c.change === "removed" ? "bad" : c.change === "added" ? "ok" : "warn"}`}>
                {c.change}
              </span>{" "}
              {c.change === "removed" ? (
                `${c.kind.slice(0, -1)} ${c.name}`
              ) : (
                <Link to={`/${c.kind}/${encodeURIComponent(c.name)}`}>
                  {c.kind.slice(0, -1)} {c.name}
                </Link>
              )}
              {c.fields.length > 0 ? <span className="muted"> ({c.fields.join(", ")})</span> : null}
            </li>
          ))}
        </ul>
      )}
      <div className="buttons">
        <button type="button" onClick={() => validate.mutate()} disabled={validate.isPending}>
          Validate
        </button>
      </div>
      <ErrorBox error={validate.error} />
      {v ? (
        v.valid ? (
          <Notice kind="ok">The staged configuration is valid.</Notice>
        ) : (
          <div className="alert error">
            The staged configuration has errors:
            <ul>
              {(v.errors ?? []).map((e, i) => (
                <li key={i}>{formatSchemaError(e)}</li>
              ))}
            </ul>
          </div>
        )
      ) : null}
      {restarts.length > 0 ? (
        <Notice kind="warn">
          Activating restarts the IEC server{restarts.length > 1 ? "s" : ""} <strong>{restarts.join(", ")}</strong>: their
          SCADA connections are dropped and must reconnect.
        </Notice>
      ) : null}
      {admin ? (
        <div className="activate">
          <input placeholder="Comment (optional)" value={comment} onChange={(e) => setComment(e.target.value)} aria-label="comment" />
          {restarts.length > 0 ? (
            <ConfirmButton
              className="primary"
              question="Restart the servers and activate?"
              onConfirm={doActivate}
              disabled={activate.isPending || changes.length === 0}
            >
              Activate
            </ConfirmButton>
          ) : (
            <button type="button" className="primary" onClick={doActivate} disabled={activate.isPending || changes.length === 0}>
              {activate.isPending ? "Activating…" : "Activate"}
            </button>
          )}
          <ConfirmButton
            question="Discard all staged changes?"
            onConfirm={() => revert.mutate()}
            disabled={revert.isPending || changes.length === 0}
          >
            Discard staged changes
          </ConfirmButton>
        </div>
      ) : null}
      <ErrorBox error={activate.error} title="Not activated" />
      <ErrorBox error={revert.error} />
      {activate.isSuccess ? <Notice kind="ok">Activated as version {activate.data.vsn}.</Notice> : null}
    </section>
  );
}

function VersionsSection({ admin }: { admin: boolean }) {
  const versions = useVersions();
  const restore = useRestore();
  const [restored, setRestored] = useState<number | null>(null);
  return (
    <section className="card">
      <h2>Versions</h2>
      {versions.isPending ? <Loading /> : null}
      <ErrorBox error={versions.error ?? restore.error} />
      {restored !== null ? (
        <Notice kind="ok">
          Version {restored} loaded into the staged configuration. Activate it above to roll back.
        </Notice>
      ) : null}
      {versions.data && versions.data.length > 0 ? (
        <table>
          <thead>
            <tr>
              <th className="num">Version</th>
              <th>Activated</th>
              <th>By</th>
              <th>Comment</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {versions.data.map((v) => (
              <tr key={v.vsn}>
                <td className="num">{v.vsn}</td>
                <td>{formatDate(v.at)}</td>
                <td>{v.author}</td>
                <td>{v.comment}</td>
                <td className="actions">
                  <button
                    type="button"
                    className="link"
                    onClick={async () => download(`snmp2iec104-v${v.vsn}.json`, (await get<{ config: Config }>(`config/versions/${v.vsn}`)).config)}
                  >
                    download
                  </button>
                  {admin ? (
                    <ConfirmButton
                      className="link"
                      question={`Replace the staged configuration with version ${v.vsn}?`}
                      onConfirm={() => restore.mutate(v.vsn, { onSuccess: () => setRestored(v.vsn) })}
                    >
                      restore
                    </ConfirmButton>
                  ) : null}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      ) : versions.data ? (
        <p className="muted">No version activated yet.</p>
      ) : null}
    </section>
  );
}

function BackupSection({ admin }: { admin: boolean }) {
  const importCfg = useImport();
  const file = useRef<HTMLInputElement>(null);
  const [parsed, setParsed] = useState<{ name: string; config: unknown } | null>(null);
  const [parseError, setParseError] = useState<string | null>(null);
  const exportCfg = async (source: "staged" | "active") =>
    download(`snmp2iec104-${source}.json`, await get<Config>(`config/export?source=${source}`));
  return (
    <section className="card">
      <h2>Backup</h2>
      <p className="muted">Secrets are exported as encrypted envelopes; they can only be imported on a gateway with the same key file.</p>
      <div className="buttons">
        <button type="button" onClick={() => exportCfg("staged")}>
          Export staged
        </button>
        <button type="button" onClick={() => exportCfg("active")}>
          Export active
        </button>
      </div>
      {admin ? (
        <>
          <h3>Import</h3>
          <input
            ref={file}
            type="file"
            accept="application/json,.json"
            aria-label="configuration file"
            onChange={async (e) => {
              setParsed(null);
              setParseError(null);
              importCfg.reset();
              const f = e.target.files?.[0];
              if (!f) return;
              try {
                setParsed({ name: f.name, config: JSON.parse(await f.text()) });
              } catch (err) {
                setParseError((err as Error).message);
              }
            }}
          />
          {parseError ? <div className="alert error">Not JSON: {parseError}</div> : null}
          {parsed ? (
            <ConfirmButton
              className="primary"
              question={`Replace the staged configuration with ${parsed.name}?`}
              onConfirm={() =>
                importCfg.mutate(parsed.config, {
                  onSuccess: () => {
                    setParsed(null);
                    if (file.current) file.current.value = "";
                  },
                })
              }
            >
              Import {parsed.name}
            </ConfirmButton>
          ) : null}
          <ErrorBox error={importCfg.error} title="Not imported" />
          {importCfg.isSuccess ? <Notice kind="ok">Imported into the staged configuration.</Notice> : null}
        </>
      ) : null}
    </section>
  );
}

function AuditSection() {
  const [limit, setLimit] = useState(50);
  const audit = useAudit(limit);
  return (
    <section className="card">
      <h2>Audit log</h2>
      <ErrorBox error={audit.error} />
      {audit.data ? (
        <>
          <table>
            <thead>
              <tr>
                <th>When</th>
                <th>Who</th>
                <th>Action</th>
                <th>Object</th>
              </tr>
            </thead>
            <tbody>
              {audit.data.map((e) => (
                <tr key={e.id}>
                  <td>{formatDate(e.at)}</td>
                  <td>{e.actor}</td>
                  <td>{e.action.replace(/_/g, " ")}</td>
                  <td>
                    {e.kind ? `${e.kind} ` : ""}
                    {e.name ?? ""}
                    {e.vsn !== undefined ? `version ${e.vsn}` : ""}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          {audit.data.length >= limit ? (
            <button type="button" className="link" onClick={() => setLimit(limit * 4)}>
              show more
            </button>
          ) : null}
        </>
      ) : (
        <Loading />
      )}
    </section>
  );
}
