import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router";
import { afterEach, describe, expect, it, vi } from "vitest";
import fixtures from "../test/fixtures.json";
import { batches, MibsPage } from "./MibsPage";

describe("batches", () => {
  it("splits files by size and keeps big files alone", () => {
    expect(batches([], 10)).toEqual([]);
    expect(batches(["aaaa", "bbbb", "cc", "dddddddddddd", "e"], 10)).toEqual([
      ["aaaa", "bbbb", "cc"],
      ["dddddddddddd"],
      ["e"],
    ]);
  });
});

function renderPage(admin: boolean) {
  const posts: unknown[] = [];
  vi.stubGlobal(
    "fetch",
    vi.fn(async (_url: string, init?: RequestInit) => {
      if (init?.method === "POST") {
        posts.push(JSON.parse(String(init.body)));
        return new Response(JSON.stringify({ modules: [{ name: "X-MIB", origin: "uploaded", status: "missing_imports", objects: 0, missing: ["Y-MIB"] }], skipped: ["SNMPv2-SMI"] }), { status: 200 });
      }
      return new Response(JSON.stringify((fixtures as Record<string, unknown>).mibs), { status: 200 });
    }),
  );
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  render(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <MibsPage admin={admin} view="modules" />
      </MemoryRouter>
    </QueryClientProvider>,
  );
  return posts;
}

describe("MibsPage", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("lists uploaded modules and explains failures", async () => {
    renderPage(false);
    expect(await screen.findByText("IF-MIB")).toBeInTheDocument();
    expect(screen.queryByText("SNMPv2-MIB")).not.toBeInTheDocument();
    expect(screen.queryByLabelText("MIB files")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Delete" })).not.toBeInTheDocument();
    const row = screen.getByText("CLNS-MIB").closest("tr")!;
    await userEvent.click(row.querySelector("button")!);
    expect(screen.getByText("RFC-1213")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("checkbox"));
    expect(screen.getByText("SNMPv2-MIB")).toBeInTheDocument();
  });

  it("uploads the chosen files", async () => {
    const posts = renderPage(true);
    await screen.findByText("IF-MIB");
    const file = new File(["X-MIB DEFINITIONS ::= BEGIN END"], "x.mib", { type: "text/plain" });
    await userEvent.upload(screen.getByLabelText("MIB files"), file);
    await userEvent.click(screen.getByRole("button", { name: /Upload/ }));
    expect(await screen.findByText(/0 of 1 modules compiled/)).toBeInTheDocument();
    expect(screen.getByText(/skipped \(built in\): SNMPv2-SMI/)).toBeInTheDocument();
    expect(posts).toEqual([{ sources: ["X-MIB DEFINITIONS ::= BEGIN END"] }]);
  });
});
