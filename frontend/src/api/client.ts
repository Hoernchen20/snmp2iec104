// REST client for /api/v1 (docs/DESIGN.md §9.1). Every request carries the
// CSRF header the gateway requires on mutations; the session is the
// HttpOnly cookie, so nothing about it is visible here.

export interface SchemaError {
  path: (string | number)[];
  error: string;
  detail?: Record<string, unknown>;
}

export class ApiError extends Error {
  readonly status: number;
  readonly code: string;
  readonly errors: SchemaError[];

  constructor(status: number, code: string, errors: SchemaError[] = []) {
    super(describeError(code, errors));
    this.name = "ApiError";
    this.status = status;
    this.code = code;
    this.errors = errors;
  }
}

const MESSAGES: Record<string, string> = {
  unauthenticated: "Not logged in",
  invalid_credentials: "Wrong user name or password",
  forbidden: "Not allowed for your role",
  csrf: "Request blocked (CSRF protection)",
  password_change_required: "You must change your password first",
  not_found: "Not found",
  no_changes: "Nothing to activate: the staged configuration equals the active one",
  last_admin: "The last admin cannot be removed or demoted",
  invalid: "Validation failed",
  not_running: "The device is not running (disabled, not in the active configuration, or starting)",
  not_registered: "The device is not registered with the SNMP manager yet",
  timeout: "The device did not answer",
  snmp_error: "SNMP error",
  payload_too_large: "The request is too large",
  bad_request: "Bad request",
  invalid_json: "Invalid JSON",
  internal_error: "Internal error (see the gateway log)",
};

export function describeError(code: string, errors: SchemaError[] = []): string {
  const base = MESSAGES[code] ?? code;
  if (errors.length === 0) return base;
  return `${base}: ${errors.map(formatSchemaError).join("; ")}`;
}

export function formatPath(path: (string | number)[]): string {
  return path.reduce<string>(
    (acc, p) => (typeof p === "number" ? `${acc}[${p}]` : acc ? `${acc}.${p}` : p),
    "",
  );
}

export function formatSchemaError(e: SchemaError): string {
  const where = formatPath(e.path);
  const detail = e.detail ? ` ${JSON.stringify(e.detail)}` : "";
  return `${where ? where + ": " : ""}${e.error.replace(/_/g, " ")}${detail}`;
}

type Method = "GET" | "POST" | "PUT" | "DELETE";

export async function api<T>(method: Method, path: string, body?: unknown): Promise<T> {
  const headers: Record<string, string> = { "X-Requested-With": "snmp2iec104-ui" };
  if (body !== undefined) headers["Content-Type"] = "application/json";
  const res = await fetch(`/api/v1/${path}`, {
    method,
    credentials: "same-origin",
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (res.status === 204) return undefined as T;
  const text = await res.text();
  let data: unknown = undefined;
  if (text) {
    try {
      data = JSON.parse(text);
    } catch {
      throw new ApiError(res.status, res.ok ? "invalid_json" : `http_${res.status}`);
    }
  }
  if (!res.ok) {
    const d = (data ?? {}) as { error?: string; errors?: SchemaError[] };
    throw new ApiError(res.status, d.error ?? `http_${res.status}`, d.errors ?? []);
  }
  return data as T;
}

export const get = <T>(path: string) => api<T>("GET", path);
export const post = <T>(path: string, body?: unknown) => api<T>("POST", path, body ?? {});
export const put = <T>(path: string, body: unknown) => api<T>("PUT", path, body);
export const del = (path: string) => api<void>("DELETE", path);

export const enc = encodeURIComponent;
