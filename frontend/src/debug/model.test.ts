import { describe, expect, it } from "vitest";
import {
  MAX_EVENTS,
  compareOid,
  deviceReducer,
  emptyDevice,
  emptyList,
  emptyServer,
  eventListReducer,
  formatIec,
  formatSnmp,
  serverReducer,
} from "./model";

const point = (value: unknown, quality: string[] = []) => ({ type: "m_me_tf_1", value, quality, ts: 1 });

describe("device values", () => {
  const snapshot = {
    type: "subscribed" as const,
    topic: "values:device:sw1",
    history: [],
    snapshot: [{ server: "s1", coa: 1, ioa: 100, source: "sw1/temp", point: point(0, ["invalid"]) }],
  };

  it("takes the snapshot, then applies poll values and their writes", () => {
    let s = deviceReducer(emptyDevice, snapshot);
    expect(s.points["s1|1|100"].point.quality).toEqual(["invalid"]);
    s = deviceReducer(s, {
      type: "event",
      topic: "values:device:sw1",
      event: {
        at: 5,
        source: "poll",
        values: [
          {
            oid: "1.3.6.1.4.1.9.1.0",
            value: { type: "integer", value: 215 },
            datapoints: ["sw1/temp"],
            writes: [{ server: "s1", coa: 1, ioa: 100, point: point(21.5) }],
          },
        ],
      },
    });
    expect(s.points["s1|1|100"]).toMatchObject({ at: 5, point: { value: 21.5, quality: [] } });
    expect(s.oids["1.3.6.1.4.1.9.1.0"]).toMatchObject({ sent: 1, source: "poll", at: 5 });
  });

  it("marks points invalid when the device goes down, keeping the value", () => {
    let s = deviceReducer(emptyDevice, snapshot);
    s = deviceReducer(s, {
      type: "event",
      topic: "t",
      event: { at: 9, source: "down", writes: [{ server: "s1", coa: 1, ioa: 100, invalid: true }] },
    });
    expect(s.downAt).toBe(9);
    expect(s.points["s1|1|100"].point).toMatchObject({ value: 0, quality: ["invalid"] });
  });

  it("ignores writes to points it does not know", () => {
    const s = deviceReducer(emptyDevice, {
      type: "event",
      topic: "t",
      event: { at: 1, source: "trap", values: [{ oid: "1.3", value: { type: "integer", value: 1 }, datapoints: [], writes: [{ server: "x", coa: 1, ioa: 1, point: point(1) }] }] },
    });
    expect(s.points).toEqual({});
    expect(Object.keys(s.oids)).toEqual(["1.3"]);
  });
});

describe("server values", () => {
  it("replaces the snapshot and updates points by address", () => {
    let s = serverReducer(emptyServer, {
      type: "subscribed",
      topic: "values:server:s1",
      history: [],
      snapshot: [{ coa: 1, ioa: 2, ...point(0) }],
    });
    s = serverReducer(s, { type: "event", topic: "values:server:s1", event: { at: 3, points: [{ coa: 1, ioa: 2, ...point(7) }] } });
    expect(s.points["1|2"]).toMatchObject({ value: 7, at: 3 });
  });
});

describe("event lists", () => {
  it("keeps the history, appends events and caps the list", () => {
    let s = eventListReducer(emptyList, { type: "subscribed", topic: "traps", history: [{ n: 1 }] });
    s = eventListReducer(s, { type: "event", topic: "traps", event: { n: 2 } });
    expect(s.events).toEqual([{ n: 1 }, { n: 2 }]);
    // unbuffered topic after a reconnect: empty history keeps what we have
    s = eventListReducer(s, { type: "subscribed", topic: "traps", history: [] });
    expect(s.events).toHaveLength(2);
    for (let i = 0; i < MAX_EVENTS + 5; i++) s = eventListReducer(s, { type: "event", topic: "traps", event: { n: i } });
    expect(s.events).toHaveLength(MAX_EVENTS);
    expect(s.events[MAX_EVENTS - 1]).toEqual({ n: MAX_EVENTS + 4 });
  });

  it("tracks redundancy groups and errors", () => {
    let s = eventListReducer(emptyList, {
      type: "subscribed",
      topic: "iec:s1",
      history: [],
      groups: [{ name: "default", active: false, members: 0, buffer_len: 0 }],
    });
    s = eventListReducer(s, { type: "groups", topic: "iec:s1", groups: [{ name: "default", active: true, members: 1, buffer_len: 3 }] });
    expect(s.groups?.[0]).toMatchObject({ active: true, buffer_len: 3 });
    s = eventListReducer(s, { type: "error", error: "unavailable", topic: "iec:s1" });
    expect(s.error).toBe("unavailable");
  });
});

describe("formatting", () => {
  it("formats SNMP and IEC values", () => {
    expect(formatSnmp({ type: "integer", value: 3 })).toBe("3");
    expect(formatSnmp({ type: "octet_string", value: null, hex: "00ff" })).toBe("0x00ff");
    expect(formatSnmp({ type: "no_such_instance" })).toBe("no such instance");
    expect(formatIec(point(0.1 + 0.2))).toBe("0.3");
    expect(formatIec(point("on"))).toBe("on");
  });

  it("sorts OIDs numerically", () => {
    expect(["1.3.6.1.10", "1.3.6.1.2", "1.3.6"].sort(compareOid)).toEqual(["1.3.6", "1.3.6.1.2", "1.3.6.1.10"]);
  });
});
