// Client of the debug WebSocket /ws (docs/DESIGN.md §9.3, s2i_web_ws_proto).
// One connection per browser tab; any number of components subscribe to
// topics. Reconnects with backoff and subscribes again (the gateway then
// re-sends history and snapshots). Close code 4001 = the session ended: no
// reconnect.

export interface GroupStatus {
  name: string;
  active: boolean;
  members: number;
  buffer_len: number;
}

/* eslint-disable @typescript-eslint/no-explicit-any */
export type ServerMsg =
  | { type: "subscribed"; topic: string; history: any[]; snapshot?: any[]; groups?: GroupStatus[] }
  | { type: "event"; topic: string; event: any }
  | { type: "groups"; topic: string; groups: GroupStatus[] }
  | { type: "unsubscribed"; topic: string }
  | { type: "error"; error: string; topic?: string }
  | { type: "dropped"; count: number }
  | { type: "pong" };
/* eslint-enable @typescript-eslint/no-explicit-any */

export type SocketState = "connecting" | "open" | "reconnecting" | "ended";
export type TopicHandler = (msg: ServerMsg) => void;
export interface SubscribeOpts {
  level?: string;
}

interface Sub {
  opts: SubscribeOpts;
  handlers: Set<TopicHandler>;
}

export interface SocketLike {
  readyState: number;
  onopen: ((ev: Event) => void) | null;
  onclose: ((ev: CloseEvent) => void) | null;
  onmessage: ((ev: MessageEvent) => void) | null;
  onerror: ((ev: Event) => void) | null;
  send(data: string): void;
  close(code?: number): void;
}

const OPEN = 1;

export function defaultUrl(loc: Location = window.location): string {
  return `${loc.protocol === "https:" ? "wss" : "ws"}://${loc.host}/ws`;
}

export class DebugSocket {
  private ws?: SocketLike;
  private readonly subs = new Map<string, Sub>();
  private readonly listeners = new Set<(s: SocketState, dropped: number) => void>();
  private attempt = 0;
  private timer?: ReturnType<typeof setTimeout>;
  private stopped = false;
  state: SocketState = "connecting";
  dropped = 0;

  constructor(
    private readonly url: string = defaultUrl(),
    private readonly factory: (url: string) => SocketLike = (u) => new WebSocket(u) as unknown as SocketLike,
  ) {
    this.connect();
  }

  /** Subscribe `handler` to `topic`; returns the unsubscribe function. */
  subscribe(topic: string, opts: SubscribeOpts, handler: TopicHandler): () => void {
    let sub = this.subs.get(topic);
    if (!sub) {
      sub = { opts, handlers: new Set() };
      this.subs.set(topic, sub);
      this.send({ op: "subscribe", topic, ...opts });
    }
    sub.handlers.add(handler);
    return () => {
      const s = this.subs.get(topic);
      if (!s) return;
      s.handlers.delete(handler);
      if (s.handlers.size === 0) {
        this.subs.delete(topic);
        this.send({ op: "unsubscribe", topic });
      }
    };
  }

  onState(fn: (s: SocketState, dropped: number) => void): () => void {
    this.listeners.add(fn);
    fn(this.state, this.dropped);
    return () => this.listeners.delete(fn);
  }

  close(): void {
    this.stopped = true;
    clearTimeout(this.timer);
    this.ws?.close(1000);
  }

  private setState(s: SocketState) {
    this.state = s;
    this.listeners.forEach((fn) => fn(s, this.dropped));
  }

  private send(msg: object) {
    if (this.ws && this.ws.readyState === OPEN) this.ws.send(JSON.stringify(msg));
  }

  private connect() {
    const ws = this.factory(this.url);
    this.ws = ws;
    ws.onopen = () => {
      this.attempt = 0;
      this.setState("open");
      for (const [topic, sub] of this.subs) this.send({ op: "subscribe", topic, ...sub.opts });
    };
    ws.onmessage = (ev) => {
      let msg: ServerMsg;
      try {
        msg = JSON.parse(String(ev.data));
      } catch {
        return;
      }
      if (msg.type === "dropped") {
        this.dropped += msg.count;
        this.setState(this.state);
        return;
      }
      if ("topic" in msg && msg.topic) this.subs.get(msg.topic)?.handlers.forEach((h) => h(msg));
    };
    ws.onclose = (ev) => {
      if (this.stopped) return;
      if (ev.code === 4001) {
        this.setState("ended");
        return;
      }
      this.setState("reconnecting");
      const delay = Math.min(1000 * 2 ** this.attempt, 15000);
      this.attempt += 1;
      this.timer = setTimeout(() => this.connect(), delay);
    };
    ws.onerror = () => undefined;
  }
}
