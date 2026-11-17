// MIB library (docs/DESIGN.md §13): upload and compile MIB modules, browse the
// OID tree. UI assist only: the gateway polls and routes numeric OIDs.
import { useEffect, useState, type FormEvent } from "react";
import { useNavigate, useSearchParams } from "react-router";
import { enc } from "../api/client";
import { useDeleteMib, useMibs, useOidNode, useOidSearch, useUploadMibs } from "../api/hooks";
import type { MibModule, MibUploadResult, OidDetail, OidInfo } from "../api/types";
import { ConfirmButton, ErrorBox, Loading, Notice, Tabs, formatDate } from "../components/ui";
import { OidName } from "../mib/Oid";
import { useResolvedName } from "../mib/names";

/** Stay well below the API's 8 MB request limit (JSON escaping adds a little). */
export const BATCH_CHARS = 6_000_000;

/** Files into upload batches of at most `limit` characters each. */
export function batches(texts: string[], limit = BATCH_CHARS): string[][] {
  const out: string[][] = [];
  let cur: string[] = [];
  let size = 0;
  for (const t of texts) {
    if (cur.length > 0 && size + t.length > limit) {
      out.push(cur);
      cur = [];
      size = 0;
    }
    cur.push(t);
    size += t.length;
  }
  if (cur.length > 0) out.push(cur);
  return out;
}

const STATUS: Record<string, string> = {
  ok: "ok",
  pending: "muted",
  error: "bad",
  missing_imports: "warn",
  dependency_failed: "warn",
};

function StatusBadge({ status }: { status: string }) {
  return <span className={`badge ${STATUS[status] ?? "muted"}`}>{status.replace(/_/g, " ")}</span>;
}

export function MibsPage({ admin, view }: { admin: boolean; view: "modules" | "browse" }) {
  const navigate = useNavigate();
  return (
    <div className="page">
      <h1>MIBs</h1>
      <p className="muted">
        Names for OIDs in the UI: tables, traps, the OID browser and the OID fields of profiles. The gateway itself
        polls and routes numeric OIDs; a MIB that fails to compile never blocks the configuration.
      </p>
      <Tabs
        tabs={[
          { id: "modules", label: "Modules" },
          { id: "browse", label: "OID browser" },
        ]}
        value={view}
        onChange={(t) => navigate(t === "modules" ? "/mibs" : "/mibs/browse")}
      />
      {view === "modules" ? <Modules admin={admin} /> : <Browser />}
    </div>
  );
}

// --- modules ------------------------------------------------------------------------

function Modules({ admin }: { admin: boolean }) {
  const mibs = useMibs();
  const del = useDeleteMib();
  const [showBuiltin, setShowBuiltin] = useState(false);
  const [open, setOpen] = useState<string | null>(null);
  if (mibs.isPending) return <Loading what="MIBs" />;
  if (mibs.isError) return <ErrorBox error={mibs.error} />;
  const uploaded = mibs.data.filter((m) => m.origin === "uploaded");
  const failed = uploaded.filter((m) => m.status !== "ok" && m.status !== "pending").length;
  const shown = showBuiltin ? mibs.data : uploaded;
  return (
    <>
      {admin ? <Upload /> : null}
      <div className="toolbar">
        <span>
          {uploaded.length} uploaded{failed > 0 ? `, ${failed} not compiled` : ""}
        </span>
        <label className="inline-check">
          <input type="checkbox" checked={showBuiltin} onChange={(e) => setShowBuiltin(e.target.checked)} /> show
          the {mibs.data.length - uploaded.length} built-in modules (shipped with OTP)
        </label>
      </div>
      <ErrorBox error={del.error} />
      {shown.length === 0 ? (
        <p className="muted">No MIBs uploaded yet.</p>
      ) : (
        <table>
          <thead>
            <tr>
              <th>Module</th>
              <th>Status</th>
              <th className="num">Objects</th>
              <th>Imports</th>
              <th>Uploaded</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {shown.map((m) => (
              <ModuleRow
                key={m.name}
                m={m}
                admin={admin}
                open={open === m.name}
                toggle={() => setOpen(open === m.name ? null : m.name)}
                onDelete={() => del.mutate(m.name)}
              />
            ))}
          </tbody>
        </table>
      )}
    </>
  );
}

function ModuleRow({
  m,
  admin,
  open,
  toggle,
  onDelete,
}: {
  m: MibModule;
  admin: boolean;
  open: boolean;
  toggle: () => void;
  onDelete: () => void;
}) {
  const problems = (m.messages?.length ?? 0) + (m.missing?.length ?? 0) + (m.dependencies?.length ?? 0);
  return (
    <>
      <tr>
        <td className="mono">{m.name}</td>
        <td>
          <StatusBadge status={m.status} /> {m.origin === "builtin" ? <span className="badge muted">built-in</span> : null}
          {problems > 0 ? (
            <button type="button" className="link small" onClick={toggle} aria-expanded={open}>
              {open ? "hide" : "why?"}
            </button>
          ) : null}
        </td>
        <td className="num">{m.objects}</td>
        <td className="small">{(m.imports ?? []).join(", ")}</td>
        <td>{m.uploaded_at ? `${formatDate(m.uploaded_at)} (${m.uploaded_by})` : "—"}</td>
        <td className="actions">
          <a href={`/api/v1/mibs/${enc(m.name)}/source`} target="_blank" rel="noreferrer">
            source
          </a>
          {admin && m.origin === "uploaded" ? (
            <ConfirmButton className="small" question={`Delete ${m.name}?`} onConfirm={onDelete}>
              Delete
            </ConfirmButton>
          ) : null}
        </td>
      </tr>
      {open ? (
        <tr className="detail">
          <td colSpan={6}>
            <Problems m={m} />
          </td>
        </tr>
      ) : null}
    </>
  );
}

function Problems({ m }: { m: MibModule }) {
  return (
    <div className="problems">
      {m.missing?.length ? (
        <p>
          Imports modules that are not uploaded: <strong className="mono">{m.missing.join(", ")}</strong>. Upload
          them and this module is compiled.
        </p>
      ) : null}
      {m.dependencies?.length ? (
        <p>
          Imports modules that could not be compiled: <strong className="mono">{m.dependencies.join(", ")}</strong>.
        </p>
      ) : null}
      {m.messages?.length ? (
        <ul className="mono small">
          {m.messages.map((e, i) => (
            <li key={i}>
              {e.line ? `line ${e.line}: ` : ""}
              {e.message}
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}

function readText(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(String(r.result));
    r.onerror = () => reject(r.error ?? new Error(`cannot read ${file.name}`));
    r.readAsText(file);
  });
}

function Upload() {
  const upload = useUploadMibs();
  const [files, setFiles] = useState<File[]>([]);
  const [readError, setReadError] = useState<string | null>(null);
  const [result, setResult] = useState<MibUploadResult | null>(null);
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setReadError(null);
    setResult(null);
    const tooBig = files.filter((f) => f.size > BATCH_CHARS);
    if (tooBig.length > 0) {
      setReadError(`Too large (at most 6 MB per file): ${tooBig.map((f) => f.name).join(", ")}`);
      return;
    }
    let texts: string[];
    try {
      texts = await Promise.all(files.map(readText));
    } catch (err) {
      setReadError(String(err));
      return;
    }
    upload.mutate(batches(texts), { onSuccess: setResult });
  };
  return (
    <section className="card">
      <h2>Upload</h2>
      <form className="inline" onSubmit={submit}>
        <input
          type="file"
          multiple
          aria-label="MIB files"
          onChange={(e) => setFiles(Array.from(e.target.files ?? []))}
        />
        <button type="submit" className="primary" disabled={files.length === 0 || upload.isPending}>
          {upload.isPending ? "Compiling…" : `Upload ${files.length || ""}`}
        </button>
      </form>
      <p className="muted small">
        Text files with one or more MIB modules (SMIv1 or SMIv2), in any order: modules are compiled after the ones
        they import. A module with the name of an existing one replaces it.
      </p>
      {readError ? <div className="alert error">{readError}</div> : null}
      <ErrorBox error={upload.error} />
      {result ? <UploadResult result={result} /> : null}
    </section>
  );
}

function UploadResult({ result }: { result: MibUploadResult }) {
  const ok = result.modules.filter((m) => m.status === "ok").length;
  return (
    <Notice kind={ok === result.modules.length ? "ok" : "warn"}>
      {ok} of {result.modules.length} modules compiled
      {result.skipped.length ? `; skipped (built in): ${result.skipped.join(", ")}` : ""}.
      {result.modules
        .filter((m) => m.status !== "ok")
        .map((m) => (
          <div key={m.name}>
            <span className="mono">{m.name}</span> <StatusBadge status={m.status} />
            <Problems m={m} />
          </div>
        ))}
    </Notice>
  );
}

// --- browser --------------------------------------------------------------------------

const ROOT = "1.3.6.1";

function Browser() {
  const [params, setParams] = useSearchParams();
  const oid = params.get("oid") ?? ROOT;
  const q = params.get("q") ?? "";
  const go = (o: string) => setParams(q ? { oid: o, q } : { oid: o });
  return (
    <div className="mib-browser">
      <aside>
        <Search q={q} setQ={(v) => setParams(v ? { oid, q: v } : { oid })} go={go} />
      </aside>
      <section>
        <Node oid={oid} go={go} />
      </section>
    </div>
  );
}

function Search({ q, setQ, go }: { q: string; setQ: (q: string) => void; go: (oid: string) => void }) {
  const [text, setText] = useState(q);
  useEffect(() => setText(q), [q]);
  useEffect(() => {
    const t = setTimeout(() => {
      if (text !== q) setQ(text);
    }, 300);
    return () => clearTimeout(t);
  }, [text, q, setQ]);
  const numeric = /^\.?\d+(\.\d+)*$/.test(text.trim());
  const search = useOidSearch(numeric ? "" : q);
  const resolved = useResolvedName(!numeric && /::|\./.test(text.trim()) ? text.trim() : undefined);
  return (
    <>
      <input
        value={text}
        placeholder="Name, MODULE::name.index or OID"
        aria-label="search MIBs"
        onChange={(e) => setText(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" && numeric) go(text.trim().replace(/^\./, ""));
          if (e.key === "Enter" && resolved?.oid) go(resolved.oid);
        }}
        spellCheck={false}
      />
      {numeric ? (
        <p className="small">
          <button type="button" className="link" onClick={() => go(text.trim().replace(/^\./, ""))}>
            Go to {text.trim()}
          </button>
        </p>
      ) : null}
      {resolved?.oid ? (
        <p className="small">
          <button type="button" className="link" onClick={() => go(resolved.oid!)}>
            Go to {resolved.name} = {resolved.oid}
          </button>
        </p>
      ) : null}
      {search.isError ? <ErrorBox error={search.error} /> : null}
      {search.data ? (
        search.data.length === 0 ? (
          <p className="muted">Nothing found.</p>
        ) : (
          <ul className="search-results">
            {search.data.map((d) => (
              <li key={d.oid}>
                <button type="button" className="link" onClick={() => go(d.oid)}>
                  {d.name}
                </button>{" "}
                <span className="muted small">
                  {d.module} · {d.kind}
                </span>
              </li>
            ))}
          </ul>
        )
      ) : (
        <p className="muted small">Type at least two characters of a name.</p>
      )}
    </>
  );
}

function Node({ oid, go }: { oid: string; go: (oid: string) => void }) {
  const node = useOidNode(oid);
  if (node.isPending) return <Loading />;
  if (node.isError) return <ErrorBox error={node.error} />;
  const n = node.data;
  return (
    <>
      <nav className="breadcrumb mono" aria-label="OID path">
        {n.path.map((p) => (
          <span key={p.oid}>
            <button type="button" className="link" onClick={() => go(p.oid)} title={p.oid}>
              {p.name ?? p.oid.split(".").pop()}
            </button>
            {" . "}
          </span>
        ))}
        <strong>{n.def?.name ?? n.oid.split(".").pop()}</strong>
      </nav>
      {n.def ? <Definition def={n.def} /> : <p className="mono">{n.oid}</p>}
      <h3>Children</h3>
      {n.children.length === 0 ? (
        <p className="muted">None known.</p>
      ) : (
        <table className="compact">
          <thead>
            <tr>
              <th className="num">Arc</th>
              <th>Name</th>
              <th>Kind</th>
              <th>Syntax</th>
              <th>Module</th>
            </tr>
          </thead>
          <tbody>
            {n.children.map((c) => (
              <tr key={c.oid}>
                <td className="num">{c.arc}</td>
                <td>
                  <button type="button" className="link mono" onClick={() => go(c.oid)}>
                    {c.name ?? c.oid}
                  </button>
                  {c.has_children ? " …" : ""}
                </td>
                <td>{c.kind ?? ""}</td>
                <td className="mono">{c.syntax ?? ""}</td>
                <td className="small">{c.module ?? ""}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </>
  );
}

function Definition({ def }: { def: OidDetail }) {
  const objects = (def.objects ?? []) as unknown as Partial<OidInfo>[];
  const rows: [string, string | undefined][] = [
    ["OID", def.oid],
    ["Module", def.module],
    ["Kind", def.kind],
    ["Syntax", def.syntax && def.base_type && def.syntax !== def.base_type ? `${def.syntax} (${def.base_type})` : def.syntax],
    ["Range", def.range ? def.range.join(" .. ") : undefined],
    ["Units", def.units],
    ["Access", def.access],
  ];
  const instance = def.kind === "scalar" ? `${def.oid}.0` : def.kind === "column" ? `${def.oid}.{index}` : undefined;
  return (
    <div className="card">
      <h2 className="mono">
        {def.module}::{def.name}
      </h2>
      <dl className="props">
        {rows
          .filter(([, v]) => v)
          .map(([k, v]) => (
            <div key={k}>
              <dt>{k}</dt>
              <dd className="mono">{v}</dd>
            </div>
          ))}
        {instance ? (
          <div>
            <dt>Datapoint OID</dt>
            <dd className="mono" title="what a profile datapoint polls">
              {instance}
            </dd>
          </div>
        ) : null}
      </dl>
      {def.description ? <p className="pre description">{def.description}</p> : null}
      {def.enums?.length ? (
        <>
          <h3>Values</h3>
          <p className="muted small">For an enum transform: map these values to the IEC states.</p>
          <table className="compact narrow">
            <tbody>
              {def.enums.map((e) => (
                <tr key={e.value}>
                  <td className="num mono">{e.value}</td>
                  <td className="mono">{e.name}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </>
      ) : null}
      {def.bits?.length ? (
        <>
          <h3>Bits</h3>
          <table className="compact narrow">
            <tbody>
              {def.bits.map((b) => (
                <tr key={b.bit}>
                  <td className="num mono">{b.bit}</td>
                  <td className="mono">{b.name}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </>
      ) : null}
      {objects.length ? (
        <>
          <h3>Objects</h3>
          <ul>
            {objects.map((o) => (
              <li key={o.oid}>
                <OidName oid={o.oid!} info={o.name ? (o as OidInfo) : null} />
              </li>
            ))}
          </ul>
        </>
      ) : null}
    </div>
  );
}
