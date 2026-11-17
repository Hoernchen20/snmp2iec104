-module(s2i_web_ws_proto).
-moduledoc """
WebSocket debug protocol (pure, docs/DESIGN.md §9.3).

Client → server (JSON text frames):

```json
{"op": "subscribe", "topic": "values:device:sw1"}
{"op": "subscribe", "topic": "log", "level": "warning"}
{"op": "unsubscribe", "topic": "traps"}
{"op": "ping"}
```

Server → client: `subscribed` (with `history`, and `snapshot` for value
topics / `groups` for `iec:*`), `unsubscribed`, `event`, `groups`
(redundancy groups of a subscribed server, every few seconds), `dropped`
(events lost to the rate limit), `error`, `pong`.

`event/2` turns the Erlang debug events of `s2i_debug` into JSON-ready
maps: OIDs dotted, SNMP values `#{type, value}` (octet strings as text
when printable, always with `hex`), IEC writes `#{server, coa, ioa, point |
invalid}`, everything else through `s2i_web_json:sanitize/1`.
""".

-export([topic/1, decode/1, log_passes/2, origin_ok/3, event/2, server_snapshot/1, device_snapshot/1,
         limit_new/1, limit/2, dropped/1, take_dropped/1]).
-export_type([limiter/0]).

-define(MAX_NAME, 128).
-define(LEVELS, [emergency, alert, critical, error, warning, notice, info, debug]).

-type kind() :: device_values | server_values | trace | iec | traps | log.
-opaque limiter() :: #{rate := pos_integer(), window := integer() | undefined, n := non_neg_integer(),
                       dropped := non_neg_integer()}.

%%% ===========================================================================
%%% Topics and client messages
%%% ===========================================================================

-spec topic(term()) -> {ok, {kind(), binary() | undefined}} | error.
topic(<<"traps">>) -> {ok, {traps, undefined}};
topic(<<"log">>) -> {ok, {log, undefined}};
topic(<<"values:device:", N/binary>>) -> named(device_values, N);
topic(<<"values:server:", N/binary>>) -> named(server_values, N);
topic(<<"snmp:trace:", N/binary>>) -> named(trace, N);
topic(<<"iec:", N/binary>>) -> named(iec, N);
topic(_) -> error.

named(Kind, N) when byte_size(N) > 0, byte_size(N) =< ?MAX_NAME ->
    case re:run(N, "^[^\\x00-\\x1f\\x7f]+$", [unicode]) of
        {match, _} -> {ok, {Kind, N}};
        nomatch -> error
    end;
named(_Kind, _N) ->
    error.

-spec decode(binary()) -> {subscribe, binary(), map()} | {unsubscribe, binary()} | ping
                              | {error, invalid_json | invalid_message | invalid_topic | invalid_level}.
decode(Frame) ->
    try json:decode(Frame) of
        #{<<"op">> := <<"ping">>} ->
            ping;
        #{<<"op">> := <<"subscribe">>} = M ->
            with_topic(M, fun(T) ->
                                  case level(maps:get(<<"level">>, M, undefined)) of
                                      {ok, undefined} -> {subscribe, T, #{}};
                                      {ok, L} -> {subscribe, T, #{level => L}};
                                      error -> {error, invalid_level}
                                  end
                          end);
        #{<<"op">> := <<"unsubscribe">>} = M ->
            with_topic(M, fun(T) -> {unsubscribe, T} end);
        _ ->
            {error, invalid_message}
    catch
        error:_ -> {error, invalid_json}
    end.

with_topic(#{<<"topic">> := T}, Fun) ->
    case topic(T) of
        {ok, _} -> Fun(T);
        error -> {error, invalid_topic}
    end;
with_topic(_, _Fun) ->
    {error, invalid_topic}.

level(undefined) -> {ok, undefined};
level(B) when is_binary(B) ->
    case [L || L <- ?LEVELS, atom_to_binary(L) =:= B] of
        [L] -> {ok, L};
        [] -> error
    end;
level(_) -> error.

-doc "Whether a log event of `Level` passes the subscriber's minimum level.".
-spec log_passes(logger:level(), logger:level() | undefined) -> boolean().
log_passes(_Level, undefined) -> true;
log_passes(Level, Min) -> logger:compare_levels(Level, Min) =/= lt.

-doc """
Whether a WebSocket upgrade with `Origin` may use the session cookie: no
`Origin` (not a browser), the request's own host (any scheme or port, so it
works behind a reverse proxy), or one of `Allowed` (exact origins).
""".
-spec origin_ok(binary() | undefined, binary(), [binary()]) -> boolean().
origin_ok(undefined, _Host, _Allowed) ->
    true;
origin_ok(Origin, Host, Allowed) ->
    lists:member(Origin, Allowed)
        orelse case uri_string:parse(Origin) of
                   #{scheme := S, host := H} when S =:= <<"http">>; S =:= <<"https">> ->
                       string:lowercase(H) =:= string:lowercase(Host);
                   _ ->
                       false
               end.

%%% ===========================================================================
%%% Events
%%% ===========================================================================

-spec event(binary(), map()) -> map().
event(<<"values:device:", _/binary>>, Ev) ->
    s2i_web_json:sanitize(maps:map(fun(values, Vs) -> [device_value(V) || V <- Vs];
                                      (writes, Ws) -> [write(W) || W <- Ws];
                                      (_, X) -> X
                                   end, Ev));
event(<<"values:server:", _/binary>>, #{points := Ps} = Ev) ->
    s2i_web_json:sanitize(Ev#{points := server_snapshot(Ps)});
event(<<"snmp:trace:", _/binary>>, Ev) ->
    s2i_web_json:sanitize(maps:map(fun(oids, Os) -> [s2i_web_json:oid(O) || O <- Os];
                                      (varbinds, Vbs) -> [s2i_web_json:varbind(V) || V <- Vbs];
                                      (_, X) -> X
                                   end, Ev));
event(<<"traps">>, Ev) ->
    s2i_web_json:sanitize(maps:map(fun(trap_oid, undefined) -> null;
                                      (trap_oid, O) -> s2i_web_json:oid(O);
                                      (varbinds, Vbs) -> [maps:merge(#{oid => s2i_web_json:oid(O)}, value(V))
                                                          || {O, V} <- Vbs];
                                      (misses, Ms) -> [#{rule => R, reason => Why} || {R, Why} <- Ms];
                                      (_, X) -> X
                                   end, Ev));
event(_Topic, Ev) ->
    s2i_web_json:sanitize(Ev).

device_value(#{oid := Oid, value := V, writes := Ws} = DV) ->
    DV#{oid := s2i_web_json:oid(Oid), value := value(V), writes := [write(W) || W <- Ws]}.

write({S, {C, I}, invalid}) -> #{server => S, coa => C, ioa => I, invalid => true};
write({S, {C, I}, Spec}) -> #{server => S, coa => C, ioa => I, point => Spec}.

%% s2i_transform:snmp_value() (and {error, Status} of a failed poll)
value(A) when is_atom(A) -> #{type => A};
value({octet_string, B}) -> octets(B);
value({oid, O}) when is_list(O) -> #{type => oid, value => s2i_web_json:oid(O)};
value({T, V}) -> #{type => T, value => V};
value(Other) -> #{type => unknown, value => Other}.

octets(B) ->
    Hex = binary:encode_hex(B, lowercase),
    Text = case unicode:characters_to_binary(B) of
               B ->
                   case io_lib:printable_unicode_list(unicode:characters_to_list(B)) of
                       true -> B;
                       false -> null
                   end;
               _ ->
                   null
           end,
    #{type => octet_string, value => Text, hex => Hex}.

-doc "Current values of a server (`s2i_live:values/1`) as JSON-ready maps.".
-spec server_snapshot([{{non_neg_integer(), non_neg_integer()}, map()}]) -> [map()].
server_snapshot(Points) ->
    [s2i_web_json:sanitize(maps:merge(Spec, #{coa => C, ioa => I})) || {{C, I}, Spec} <- Points].

-doc "Points of a device (`s2i_live:device_values/1`) as JSON-ready maps.".
-spec device_snapshot([{binary(), {non_neg_integer(), non_neg_integer()}, map(), map()}]) -> [map()].
device_snapshot(Points) ->
    [s2i_web_json:sanitize(#{server => S, coa => C, ioa => I, source => source(Src), point => Spec})
     || {S, {C, I}, #{source := Src}, Spec} <- Points].

source({datapoint, Id}) -> Id;
source({comm_status, _}) -> <<"comm_status">>.

%%% ===========================================================================
%%% Rate limit: at most `Rate` events per one-second window
%%% ===========================================================================

-spec limit_new(pos_integer()) -> limiter().
limit_new(Rate) ->
    #{rate => Rate, window => undefined, n => 0, dropped => 0}.

-spec limit(integer(), limiter()) -> {ok | drop, limiter()}.
limit(NowMs, #{window := W} = L) when W =/= NowMs div 1000 ->
    limit(NowMs, L#{window := NowMs div 1000, n := 0});
limit(_NowMs, #{rate := Rate, n := N} = L) when N < Rate ->
    {ok, L#{n := N + 1}};
limit(_NowMs, #{dropped := D} = L) ->
    {drop, L#{dropped := D + 1}}.

-spec dropped(limiter()) -> non_neg_integer().
dropped(#{dropped := D}) -> D.

-doc "The number of dropped events since the last call, and reset it.".
-spec take_dropped(limiter()) -> {non_neg_integer(), limiter()}.
take_dropped(#{dropped := D} = L) -> {D, L#{dropped := 0}}.
