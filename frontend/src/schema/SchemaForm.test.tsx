import { fireEvent, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { SchemaError } from "../api/client";
import { resetOidNames } from "../mib/names";
import { SchemaForm, parseChoice } from "./SchemaForm";
import type { JsonSchema } from "./types";

const schema: JsonSchema = {
  type: "object",
  required: ["name", "transport", "snmp"],
  "x-order": ["name", "port", "transport", "snmp", "groups", "tags"],
  properties: {
    name: { type: "string" },
    port: { type: "integer", minimum: 1, maximum: 65535, default: 161 },
    transport: {
      discriminator: { propertyName: "kind" },
      oneOf: [
        { type: "object", required: ["kind"], properties: { kind: { type: "string", const: "tcp" }, ip: { type: "string" } } },
        {
          type: "object",
          required: ["kind", "certfile"],
          properties: { kind: { type: "string", const: "tls" }, ip: { type: "string" }, certfile: { type: "string" } },
        },
      ],
    },
    snmp: {
      type: "object",
      required: ["community"],
      properties: { community: { type: "string", writeOnly: true } },
    },
    groups: { type: "object", additionalProperties: { type: "integer" } },
    tags: { type: "array", items: { type: "integer" } },
  },
};

function Harness({ initial, errors = [], readOnly = false, spy }: { initial: unknown; errors?: SchemaError[]; readOnly?: boolean; spy?: (v: unknown) => void }) {
  const [v, setV] = useState(initial);
  return (
    <SchemaForm
      schema={schema}
      value={v}
      onChange={(nv) => {
        setV(nv);
        spy?.(nv);
      }}
      errors={errors}
      readOnly={readOnly}
      locked={["name"]}
    />
  );
}

const base = { name: "sw1", port: 161, transport: { kind: "tcp", ip: "10.0.0.1" }, snmp: { community: "enc:v1:xyz" } };

describe("SchemaForm", () => {
  it("renders fields in x-order with the locked name", () => {
    render(<Harness initial={base} />);
    const labels = screen
      .getAllByText(/^(Name|Port|Transport|Snmp|Groups|Tags)( \*)?$/)
      .map((e) => e.textContent?.replace(" *", ""));
    expect(labels).toEqual(["Name", "Port", "Transport", "Snmp", "Groups", "Tags"]);
    expect(screen.getByText("sw1")).toBeInTheDocument();
  });

  it("switches union variants and keeps shared fields", async () => {
    const spy = vi.fn();
    render(<Harness initial={base} spy={spy} />);
    await userEvent.selectOptions(screen.getByDisplayValue("tcp"), "tls");
    expect(spy).toHaveBeenLastCalledWith({ ...base, transport: { kind: "tls", ip: "10.0.0.1", certfile: "" } });
  });

  it("shows server errors at their fields", () => {
    render(<Harness initial={base} errors={[{ path: ["port"], error: "out_of_range" }, { path: ["transport", "ip"], error: "invalid_ip" }]} />);
    expect(screen.getByText("out of range")).toBeInTheDocument();
    expect(screen.getByText("invalid ip")).toBeInTheDocument();
  });

  it("keeps stored secrets unless changed", async () => {
    const spy = vi.fn();
    render(<Harness initial={base} spy={spy} />);
    expect(screen.getByText("stored, encrypted")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Change" }));
    expect(spy).toHaveBeenLastCalledWith({ ...base, snmp: { community: "" } });
    await userEvent.click(screen.getByRole("button", { name: "keep stored" }));
    expect(spy).toHaveBeenLastCalledWith(base);
  });

  it("edits numbers, lists and maps", async () => {
    const spy = vi.fn();
    render(<Harness initial={base} spy={spy} />);
    const port = screen.getByLabelText("Port");
    expect(port).toHaveValue(161);
    fireEvent.change(port, { target: { value: "" } });
    expect(spy).toHaveBeenLastCalledWith({ name: "sw1", transport: base.transport, snmp: base.snmp });
    // optional composite fields are added on demand
    const addButtons = screen.getAllByRole("button", { name: "Add" });
    await userEvent.click(addButtons[1]); // tags
    const list = screen.getByPlaceholderText("e.g. 1, 2, 3");
    await userEvent.type(list, "1, 2 x");
    fireEvent.blur(list);
    expect(spy).toHaveBeenLastCalledWith(expect.objectContaining({ tags: [1, 2, "x"] }));
    await userEvent.click(screen.getAllByRole("button", { name: "Add" })[0]); // groups
    await userEvent.type(screen.getByLabelText("new key"), "fast");
    await userEvent.click(screen.getAllByRole("button", { name: "Add" })[0]);
    expect(spy).toHaveBeenLastCalledWith(expect.objectContaining({ groups: { fast: undefined } }));
  });

  it("disables everything for viewers", () => {
    render(<Harness initial={base} readOnly />);
    expect(screen.getByDisplayValue("tcp")).toBeDisabled();
    expect(screen.getByDisplayValue("161")).toBeDisabled();
  });
});

describe("OID fields", () => {
  const oidSchema: JsonSchema = {
    type: "object",
    properties: { oid: { type: "string", format: "oid-template" } },
  };
  function OidHarness({ initial, spy }: { initial: string; spy: (v: unknown) => void }) {
    const [v, setV] = useState<unknown>({ oid: initial });
    return (
      <SchemaForm
        schema={oidSchema}
        value={v}
        onChange={(nv) => {
          setV(nv);
          spy(nv);
        }}
        errors={[]}
      />
    );
  }
  const info = {
    oid: "1.3.6.1.2.1.2.2.1.8",
    base_oid: "1.3.6.1.2.1.2.2.1.8",
    index: "",
    name: "ifOperStatus",
    module: "IF-MIB",
    kind: "column",
    syntax: "INTEGER",
    enums: [
      { value: 1, name: "up" },
      { value: 2, name: "down" },
    ],
  };

  beforeEach(() => {
    resetOidNames();
    vi.stubGlobal(
      "fetch",
      vi.fn(async (_url: string, init: RequestInit) => {
        const body = JSON.parse(String(init.body)) as { oids: string[]; names: string[] };
        return new Response(
          JSON.stringify({
            oids: body.oids.map((o) => (o === info.oid ? info : null)),
            names: body.names.map((n) => (n === "ifOperStatus" ? { name: n, oid: info.oid } : { name: n, error: "not_found" })),
          }),
        );
      }),
    );
  });
  afterEach(() => vi.unstubAllGlobals());

  it("shows the MIB name and values of a numeric OID", async () => {
    render(<OidHarness initial="1.3.6.1.2.1.2.2.1.8.{index}" spy={() => {}} />);
    expect(await screen.findByText("IF-MIB::ifOperStatus.{index}")).toBeInTheDocument();
    expect(screen.getByText(/1 up, 2 down/)).toBeInTheDocument();
  });

  it("turns a typed name into the numeric OID", async () => {
    const spy = vi.fn();
    render(<OidHarness initial="ifOperStatus" spy={spy} />);
    await userEvent.click(await screen.findByRole("button", { name: "use 1.3.6.1.2.1.2.2.1.8.{index}" }));
    expect(spy).toHaveBeenLastCalledWith({ oid: "1.3.6.1.2.1.2.2.1.8.{index}" });
  });

  it("says when a name is unknown", async () => {
    render(<OidHarness initial="nope" spy={() => {}} />);
    expect(await screen.findByText(/unknown name/)).toBeInTheDocument();
  });
});

describe("parseChoice", () => {
  const snmpValue: JsonSchema = { oneOf: [{ type: "integer" }, { type: "string" }] };
  const state: JsonSchema = { oneOf: [{ type: "boolean" }, { type: "string", enum: ["on", "off"] }, { type: "integer" }] };
  it("types the input by the allowed alternatives", () => {
    expect(parseChoice(snmpValue, "42")).toBe(42);
    expect(parseChoice(snmpValue, "up")).toBe("up");
    expect(parseChoice(snmpValue, "true")).toBe("true");
    expect(parseChoice(state, "true")).toBe(true);
    expect(parseChoice(state, "on")).toBe("on");
    expect(parseChoice(state, "-3")).toBe(-3);
  });
});
