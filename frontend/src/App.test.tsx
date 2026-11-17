// Smoke test of every page against API responses recorded from a running
// gateway (src/test/fixtures.json): each renders its content without errors.
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { App } from "./App";
import fixtures from "./test/fixtures.json";

type Fx = Record<string, unknown>;

class FakeWebSocket {
  readyState = 0;
  onopen = null;
  onclose = null;
  onmessage = null;
  onerror = null;
  send() {}
  close() {}
}

function serve(overrides: Fx = {}) {
  const data: Fx = { ...(fixtures as Fx), ...overrides };
  vi.stubGlobal(
    "fetch",
    vi.fn(async (url: string) => {
      const path = url.replace(/^\/api\/v1\//, "");
      if (!(path in data)) return new Response(JSON.stringify({ error: "not_found" }), { status: 404 });
      const body = data[path];
      if (body instanceof Response) return body;
      return new Response(JSON.stringify(body), { status: 200 });
    }),
  );
}

function renderAt(route: string) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  render(
    <QueryClientProvider client={qc}>
      <MemoryRouter initialEntries={[route]}>
        <App />
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

describe("App", () => {
  let consoleError: ReturnType<typeof vi.spyOn>;
  beforeEach(() => {
    vi.stubGlobal("WebSocket", FakeWebSocket);
    consoleError = vi.spyOn(console, "error");
  });
  afterEach(() => {
    expect(consoleError).not.toHaveBeenCalled();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it.each([
    ["/", "Status", "dev1"],
    ["/devices", "Devices", "dev1"],
    ["/devices/dev1", "Community", "stored, encrypted"],
    ["/profiles", "Profiles", "basic"],
    ["/profiles/basic", "Datapoints", "uptime"],
    ["/servers", "IEC servers", "scada"],
    ["/servers/scada", "Transport", "Common addresses"],
    ["/config", "Staged changes", "Audit log"],
    ["/debug?view=device&name=dev1", "Live debug", "IEC points of dev1"],
    ["/debug?view=log", "Live debug", "Minimum level"],
    ["/tools?device=dev1", "SNMP tools", "Walk"],
    ["/users", "New user", "admin"],
    ["/account", "Account", "Change password"],
  ])("renders %s", async (route, first, second) => {
    serve();
    renderAt(route);
    expect((await screen.findAllByText(first)).length).toBeGreaterThan(0);
    expect((await screen.findAllByText(second, { exact: false })).length).toBeGreaterThan(0);
  });

  it("shows the login form without a session", async () => {
    serve({ me: new Response(JSON.stringify({ error: "unauthenticated" }), { status: 401 }) });
    renderAt("/devices");
    expect(await screen.findByRole("button", { name: "Log in" })).toBeInTheDocument();
  });

  it("forces the password change first", async () => {
    serve({ me: { name: "admin", role: "admin", must_change_password: true } });
    renderAt("/");
    expect(await screen.findByText("Change your password")).toBeInTheDocument();
    expect(screen.queryByText("Devices")).not.toBeInTheDocument();
  });

  it("hides admin pages from viewers", async () => {
    serve({ me: { name: "view", role: "viewer", must_change_password: false } });
    renderAt("/devices/dev1");
    expect(await screen.findByText("read only (viewer)")).toBeInTheDocument();
    expect(screen.queryByRole("link", { name: "Users" })).not.toBeInTheDocument();
  });
});
