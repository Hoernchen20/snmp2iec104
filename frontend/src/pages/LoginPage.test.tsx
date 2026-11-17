import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { LoginPage } from "./LoginPage";

function renderLogin() {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } });
  render(
    <QueryClientProvider client={qc}>
      <LoginPage />
    </QueryClientProvider>,
  );
  return qc;
}

const reply = (status: number, body: unknown) =>
  Promise.resolve(new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } }));

describe("LoginPage", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("posts the credentials with the CSRF header and stores the user", async () => {
    const fetchMock = vi.fn(() => reply(200, { name: "admin", role: "admin", must_change_password: false }));
    vi.stubGlobal("fetch", fetchMock);
    const qc = renderLogin();
    await userEvent.type(screen.getByLabelText("User name"), "admin");
    await userEvent.type(screen.getByLabelText("Password"), "secret-password");
    await userEvent.click(screen.getByRole("button", { name: "Log in" }));
    await vi.waitFor(() => expect(qc.getQueryData(["me"])).toMatchObject({ name: "admin" }));
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe("/api/v1/login");
    expect(init.method).toBe("POST");
    expect((init.headers as Record<string, string>)["X-Requested-With"]).toBeTruthy();
    expect(JSON.parse(init.body as string)).toEqual({ username: "admin", password: "secret-password" });
  });

  it("shows a readable error for wrong credentials", async () => {
    vi.stubGlobal("fetch", vi.fn(() => reply(401, { error: "invalid_credentials" })));
    renderLogin();
    await userEvent.type(screen.getByLabelText("User name"), "admin");
    await userEvent.type(screen.getByLabelText("Password"), "nope-nope");
    await userEvent.click(screen.getByRole("button", { name: "Log in" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Wrong user name or password");
  });
});
