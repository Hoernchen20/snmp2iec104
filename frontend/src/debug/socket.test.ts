import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { DebugSocket, defaultUrl, type SocketLike } from "./socket";

class FakeWs implements SocketLike {
  readyState = 0;
  sent: unknown[] = [];
  onopen: SocketLike["onopen"] = null;
  onclose: SocketLike["onclose"] = null;
  onmessage: SocketLike["onmessage"] = null;
  onerror: SocketLike["onerror"] = null;
  send(data: string) {
    this.sent.push(JSON.parse(data));
  }
  close() {
    this.readyState = 3;
  }
  open() {
    this.readyState = 1;
    this.onopen?.(new Event("open"));
  }
  receive(msg: object) {
    this.onmessage?.({ data: JSON.stringify(msg) } as MessageEvent);
  }
  drop(code: number) {
    this.readyState = 3;
    this.onclose?.({ code } as CloseEvent);
  }
}

describe("DebugSocket", () => {
  let sockets: FakeWs[];
  const factory = () => {
    const ws = new FakeWs();
    sockets.push(ws);
    return ws;
  };

  beforeEach(() => {
    sockets = [];
    vi.useFakeTimers();
  });
  afterEach(() => vi.useRealTimers());

  it("subscribes once per topic and dispatches to every handler", () => {
    const s = new DebugSocket("ws://x/ws", factory);
    const a = vi.fn();
    const b = vi.fn();
    const offA = s.subscribe("traps", {}, a);
    s.subscribe("traps", {}, b);
    sockets[0].open();
    expect(sockets[0].sent).toEqual([{ op: "subscribe", topic: "traps" }]);
    sockets[0].receive({ type: "event", topic: "traps", event: { n: 1 } });
    sockets[0].receive({ type: "event", topic: "other", event: {} });
    expect(a).toHaveBeenCalledTimes(1);
    expect(b).toHaveBeenCalledTimes(1);
    offA();
    expect(sockets[0].sent).toHaveLength(1); // b still listens
  });

  it("unsubscribes when the last handler leaves; passes options", () => {
    const s = new DebugSocket("ws://x/ws", factory);
    sockets[0].open();
    const off = s.subscribe("log", { level: "warning" }, () => undefined);
    off();
    expect(sockets[0].sent).toEqual([
      { op: "subscribe", topic: "log", level: "warning" },
      { op: "unsubscribe", topic: "log" },
    ]);
  });

  it("reconnects with backoff and subscribes again", () => {
    const s = new DebugSocket("ws://x/ws", factory);
    const states: string[] = [];
    s.onState((st) => states.push(st));
    s.subscribe("traps", {}, () => undefined);
    sockets[0].open();
    sockets[0].drop(1006);
    expect(states).toEqual(["connecting", "open", "reconnecting"]);
    vi.advanceTimersByTime(999);
    expect(sockets).toHaveLength(1);
    vi.advanceTimersByTime(1);
    expect(sockets).toHaveLength(2);
    sockets[1].drop(1006); // failed before opening: the next wait doubles
    vi.advanceTimersByTime(1999);
    expect(sockets).toHaveLength(2);
    vi.advanceTimersByTime(1);
    expect(sockets).toHaveLength(3);
    sockets[2].open();
    expect(sockets[2].sent).toEqual([{ op: "subscribe", topic: "traps" }]);
    sockets[2].drop(1006); // after a successful open: back to 1 s
    vi.advanceTimersByTime(1000);
    expect(sockets).toHaveLength(4);
  });

  it("stops when the session ended (4001) or on close()", () => {
    const s = new DebugSocket("ws://x/ws", factory);
    sockets[0].open();
    sockets[0].drop(4001);
    expect(s.state).toBe("ended");
    vi.advanceTimersByTime(60000);
    expect(sockets).toHaveLength(1);
    const t = new DebugSocket("ws://x/ws", factory);
    t.close();
    sockets[1].drop(1000);
    vi.advanceTimersByTime(60000);
    expect(sockets).toHaveLength(2);
  });

  it("counts dropped events", () => {
    const s = new DebugSocket("ws://x/ws", factory);
    sockets[0].open();
    sockets[0].receive({ type: "dropped", count: 5 });
    sockets[0].receive({ type: "dropped", count: 2 });
    expect(s.dropped).toBe(7);
  });

  it("derives the URL from the page", () => {
    expect(defaultUrl({ protocol: "https:", host: "gw:8443" } as Location)).toBe("wss://gw:8443/ws");
    expect(defaultUrl({ protocol: "http:", host: "localhost:5173" } as Location)).toBe("ws://localhost:5173/ws");
  });
});
