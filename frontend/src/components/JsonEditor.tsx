import { useEffect, useState } from "react";

/** Raw JSON view of a value; applied on demand (invalid JSON is not lost). */
export function JsonEditor({
  value,
  onChange,
  readOnly = false,
}: {
  value: unknown;
  onChange: (v: unknown) => void;
  readOnly?: boolean;
}) {
  const shown = JSON.stringify(value, null, 2);
  const [text, setText] = useState(shown);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => setText(shown), [shown]);
  const apply = () => {
    try {
      onChange(JSON.parse(text));
      setError(null);
    } catch (e) {
      setError((e as Error).message);
    }
  };
  return (
    <div className="json-editor">
      <textarea
        spellCheck={false}
        value={text}
        readOnly={readOnly}
        onChange={(e) => setText(e.target.value)}
        rows={Math.min(40, Math.max(10, text.split("\n").length + 1))}
        aria-label="JSON"
      />
      {error ? <div className="alert error">Invalid JSON: {error}</div> : null}
      {!readOnly ? (
        <div className="buttons">
          <button type="button" onClick={apply} disabled={text === shown}>
            Apply JSON
          </button>
          <button type="button" onClick={() => setText(shown)} disabled={text === shown}>
            Reset
          </button>
        </div>
      ) : null}
    </div>
  );
}
