import { useEffect, useMemo, useState } from "react";
import { Link, useNavigate, useParams, useSearchParams } from "react-router";
import { ApiError, type SchemaError } from "../api/client";
import { useDeleteEntity, useEntity, useSaveEntity, useSchemas } from "../api/hooks";
import { LABEL, SCHEMA_OF, type EntityKind } from "../api/types";
import { ConfirmButton, ErrorBox, Loading, Notice, Tabs } from "../components/ui";
import { JsonEditor } from "../components/JsonEditor";
import { SchemaForm } from "../schema/SchemaForm";
import { initialValue, isObject } from "../schema/logic";

export function EntityEditor({ kind, admin }: { kind: EntityKind; admin: boolean }) {
  const { name = "" } = useParams();
  const [params] = useSearchParams();
  const isNew = params.get("new") === "1";
  const schemas = useSchemas();
  const entity = useEntity(kind, isNew ? undefined : name);
  const schema = schemas.data?.[SCHEMA_OF[kind]];

  const original = useMemo(() => {
    if (!schema) return undefined;
    if (isNew) {
      const v = initialValue(schema);
      return isObject(v) ? { ...v, name } : { name };
    }
    return entity.data;
  }, [schema, isNew, name, entity.data]);

  if (schemas.isPending || (!isNew && entity.isPending)) return <Loading />;
  if (schemas.isError) return <ErrorBox error={schemas.error} />;
  if (!isNew && entity.isError) {
    return (
      <div className="page">
        <ErrorBox error={entity.error} />
        <Link to={`/${kind}`}>Back to the list</Link>
      </div>
    );
  }
  if (!schema || original === undefined) return <Loading />;
  return <Editor key={`${kind}/${name}/${isNew}`} kind={kind} name={name} isNew={isNew} admin={admin} schema={schema} original={original} />;
}

function Editor({
  kind,
  name,
  isNew,
  admin,
  schema,
  original,
}: {
  kind: EntityKind;
  name: string;
  isNew: boolean;
  admin: boolean;
  schema: NonNullable<ReturnType<typeof useSchemas>["data"]>[string];
  original: unknown;
}) {
  const navigate = useNavigate();
  const save = useSaveEntity(kind);
  const remove = useDeleteEntity(kind);
  const [draft, setDraft] = useState<unknown>(original);
  const [tab, setTab] = useState<"form" | "json">("form");
  const [errors, setErrors] = useState<SchemaError[]>([]);
  const [saved, setSaved] = useState(false);
  const dirty = JSON.stringify(draft) !== JSON.stringify(original);

  // a refetch after saving brings the canonical form (defaults filled in)
  useEffect(() => setDraft(original), [original]);

  const onSave = () => {
    setSaved(false);
    save.mutate(
      { name, value: draft },
      {
        onSuccess: () => {
          setErrors([]);
          setSaved(true);
          if (isNew) navigate(`/${kind}/${encodeURIComponent(name)}`, { replace: true });
        },
        onError: (e) => setErrors(e instanceof ApiError ? e.errors : []),
      },
    );
  };

  return (
    <div className="page">
      <div className="page-head">
        <h1>
          <Link to={`/${kind}`} className="muted">
            {LABEL[kind].many}
          </Link>{" "}
          / {name}
          {isNew ? <span className="badge muted">new</span> : null}
          {dirty ? <span className="badge warn">unsaved</span> : null}
        </h1>
        {admin ? (
          <div className="buttons">
            <button type="button" onClick={() => setDraft(original)} disabled={!dirty}>
              Discard changes
            </button>
            <button type="button" className="primary" onClick={onSave} disabled={save.isPending || (!dirty && !isNew)}>
              {save.isPending ? "Saving…" : "Save"}
            </button>
            {!isNew ? (
              <ConfirmButton
                className="danger"
                question={`Delete ${name} from the staged configuration?`}
                onConfirm={() => remove.mutate(name, { onSuccess: () => navigate(`/${kind}`) })}
              >
                Delete
              </ConfirmButton>
            ) : null}
          </div>
        ) : (
          <span className="muted">read only (viewer)</span>
        )}
      </div>
      {kind === "devices" && !isNew ? (
        <p className="links">
          <Link to={`/debug?view=device&name=${encodeURIComponent(name)}`}>live values</Link>
          <Link to={`/debug?view=trace&name=${encodeURIComponent(name)}`}>SNMP trace</Link>
          <Link to={`/tools?device=${encodeURIComponent(name)}`}>SNMP tools</Link>
        </p>
      ) : null}
      {saved && !dirty ? (
        <Notice kind="ok">
          Saved to the staged configuration. <Link to="/config">Validate and activate</Link> to apply it.
        </Notice>
      ) : null}
      <ErrorBox error={save.error ?? remove.error} title="Not saved" />
      <Tabs
        tabs={[
          { id: "form", label: "Form" },
          { id: "json", label: "JSON" },
        ]}
        value={tab}
        onChange={setTab}
      />
      {tab === "form" ? (
        <SchemaForm schema={schema} value={draft} onChange={setDraft} errors={errors} readOnly={!admin} locked={["name"]} />
      ) : (
        <JsonEditor value={draft} onChange={setDraft} readOnly={!admin} />
      )}
    </div>
  );
}
