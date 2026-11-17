import { createContext, useContext, useEffect, useReducer, useRef, useState, type ReactNode } from "react";
import { DebugSocket, type ServerMsg, type SocketState, type SubscribeOpts } from "./socket";

const Ctx = createContext<() => DebugSocket>(() => {
  throw new Error("DebugSocketProvider missing");
});

/** The debug WebSocket of this tab, opened on first use, closed on logout. */
export function DebugSocketProvider({ children }: { children: ReactNode }) {
  const ref = useRef<DebugSocket | null>(null);
  useEffect(
    () => () => {
      ref.current?.close();
      ref.current = null;
    },
    [],
  );
  const get = () => (ref.current ??= new DebugSocket());
  return <Ctx.Provider value={get}>{children}</Ctx.Provider>;
}

export function useSocketState(): { state: SocketState; dropped: number } {
  const get = useContext(Ctx);
  const [s, setS] = useState<{ state: SocketState; dropped: number }>({ state: "connecting", dropped: 0 });
  useEffect(() => get().onState((state, dropped) => setS({ state, dropped })), [get]);
  return s;
}

/**
 * State of one topic, built by `reducer` from its messages; reset when the
 * topic changes. `topic === null` subscribes to nothing.
 */
export function useTopic<S>(
  topic: string | null,
  reducer: (s: S, m: ServerMsg) => S,
  initial: S,
  opts: SubscribeOpts = {},
): [S, () => void] {
  const get = useContext(Ctx);
  const [state, dispatch] = useReducer(
    (s: S, a: { reset: true } | { msg: ServerMsg }) => ("reset" in a ? initial : reducer(s, a.msg)),
    initial,
  );
  const level = opts.level;
  useEffect(() => {
    dispatch({ reset: true });
    if (topic === null) return;
    return get().subscribe(topic, level ? { level } : {}, (msg) => dispatch({ msg }));
  }, [get, topic, level]);
  return [state, () => dispatch({ reset: true })];
}
