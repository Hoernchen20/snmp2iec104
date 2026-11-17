-module(s2i_web_ws).
-moduledoc """
WebSocket debugging at `/ws` (docs/DESIGN.md §9.3); protocol in
`s2i_web_ws_proto`.

- Upgrade: session cookie with `viewer` access (no pending password
  change) and an `Origin` of the gateway's own host or one of `s2i_web`
  `ws_allowed_origins` (cross-site WebSocket hijacking). Otherwise the
  REST error reply (401 / 403).
- Every subscription is an `s2i_debug` topic; at most `?MAX_SUBS` per
  connection. `subscribed` carries the buffered history, the current values
  (`values:*`, from `s2i_live`) or the redundancy groups (`iec:*`).
- Events beyond `ws_rate_limit` per second (default 500) are dropped and
  reported once per second (`dropped`).
- Every second: the session is checked without refreshing it
  (`s2i_web_session:peek/1`); logout, expiry, deletion of the user or a
  forced password change close the socket (4001). Every
  `?GROUPS_EVERY` ticks the groups of subscribed `iec:*` servers are sent.
""".
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2]).

-define(MAX_SUBS, 32).
-define(TICK_MS, 1000).
-define(GROUPS_EVERY, 2).
-define(CLOSE_SESSION, 4001).

-spec init(cowboy_req:req(), term()) ->
          {cowboy_websocket, cowboy_req:req(), map(), map()} | {ok, cowboy_req:req(), term()}.
init(Req, Opts) ->
    Origin = cowboy_req:header(<<"origin">>, Req),
    Allowed = [unicode:characters_to_binary(O) || O <- application:get_env(s2i_web, ws_allowed_origins, [])],
    case s2i_web_api:authorize(Req, viewer) of
        {ok, Token, #{name := Name}} ->
            case s2i_web_ws_proto:origin_ok(Origin, cowboy_req:host(Req), Allowed) of
                true ->
                    State = #{token => Token, user => Name, subs => #{}, ticks => 0,
                              limiter => s2i_web_ws_proto:limit_new(
                                           application:get_env(s2i_web, ws_rate_limit, 500))},
                    {cowboy_websocket, Req, State, #{idle_timeout => 120000, max_frame_size => 65536}};
                false ->
                    logger:notice("WebSocket from ~ts refused: origin ~ts", [Name, Origin]),
                    {ok, s2i_web_api:error_reply(csrf, [], Req), Opts}
            end;
        {error, Code} ->
            {ok, s2i_web_api:error_reply(Code, [], Req), Opts}
    end.

-spec websocket_init(map()) -> {ok, map()}.
websocket_init(State) ->
    _ = erlang:send_after(?TICK_MS, self(), tick),
    {ok, State}.

-spec websocket_handle(term(), map()) -> {[cow_ws:frame()], map()} | {ok, map()}.
websocket_handle({text, Frame}, State) ->
    case s2i_web_ws_proto:decode(Frame) of
        ping -> reply([#{type => pong}], State);
        {subscribe, Topic, Opts} -> subscribe(Topic, Opts, State);
        {unsubscribe, Topic} -> unsubscribe(Topic, State);
        {error, Code} -> reply([#{type => error, error => Code}], State)
    end;
websocket_handle(_Frame, State) ->
    {ok, State}.

-spec websocket_info(term(), map()) -> {[cow_ws:frame()], map()} | {ok, map()}.
websocket_info({s2i_debug, Topic, Event}, #{subs := Subs, limiter := L} = State) ->
    case Subs of
        #{Topic := Opts} ->
            case passes(Topic, Event, Opts) of
                true ->
                    case s2i_web_ws_proto:limit(erlang:monotonic_time(millisecond), L) of
                        {ok, L1} ->
                            reply([#{type => event, topic => Topic,
                                     event => s2i_web_ws_proto:event(Topic, Event)}],
                                  State#{limiter := L1});
                        {drop, L1} ->
                            {ok, State#{limiter := L1}}
                    end;
                false ->
                    {ok, State}
            end;
        _ ->
            {ok, State}                         % left over after unsubscribe
    end;
websocket_info(tick, #{token := Token, user := Name, limiter := L, ticks := T, subs := Subs} = State) ->
    case session_valid(Token, Name) of
        false ->
            {[{close, ?CLOSE_SESSION, <<"session ended">>}], State};
        true ->
            _ = erlang:send_after(?TICK_MS, self(), tick),
            {Dropped, L1} = s2i_web_ws_proto:take_dropped(L),
            Groups = case (T + 1) rem ?GROUPS_EVERY of
                         0 -> [#{type => groups, topic => Topic, groups => groups(S)}
                               || Topic := _ <- Subs, {ok, {iec, S}} <- [s2i_web_ws_proto:topic(Topic)]];
                         _ -> []
                     end,
            reply([#{type => dropped, count => Dropped} || Dropped > 0] ++ Groups,
                  State#{limiter := L1, ticks := T + 1})
    end;
websocket_info(_Msg, State) ->
    {ok, State}.

%%% ===========================================================================

subscribe(Topic, _Opts, #{subs := Subs} = State) when map_size(Subs) >= ?MAX_SUBS,
                                                       not is_map_key(Topic, Subs) ->
    reply([#{type => error, error => too_many_subscriptions, topic => Topic}], State);
subscribe(Topic, Opts, #{subs := Subs} = State) ->
    try s2i_debug:subscribe(Topic) of
        {ok, History} ->
            {ok, {Kind, Name}} = s2i_web_ws_proto:topic(Topic),
            Msg = maps:merge(#{type => subscribed, topic => Topic,
                               history => [s2i_web_ws_proto:event(Topic, E)
                                           || E <- History, passes(Topic, E, Opts)]},
                             initial(Kind, Name)),
            reply([Msg], State#{subs := Subs#{Topic => Opts}})
    catch
        exit:_ -> reply([#{type => error, error => unavailable, topic => Topic}], State)
    end.

unsubscribe(Topic, #{subs := Subs} = State) ->
    ok = s2i_debug:unsubscribe(Topic),
    reply([#{type => unsubscribed, topic => Topic}], State#{subs := maps:remove(Topic, Subs)}).

initial(server_values, S) -> #{snapshot => s2i_web_ws_proto:server_snapshot(s2i_live:values(S))};
initial(device_values, D) -> #{snapshot => s2i_web_ws_proto:device_snapshot(s2i_live:device_values(D))};
initial(iec, S) -> #{groups => groups(S)};
initial(_Kind, _Name) -> #{}.

groups(Server) ->
    s2i_web_json:sanitize(s2i_iec:groups(Server)).

passes(<<"log">>, #{level := Level}, Opts) ->
    s2i_web_ws_proto:log_passes(Level, maps:get(level, Opts, undefined));
passes(_Topic, _Event, _Opts) ->
    true.

session_valid(Token, Name) ->
    case s2i_web_session:peek(Token) of
        {ok, Name} ->
            case s2i_users:get(Name) of
                {ok, #{must_change_password := false}} -> true;
                _ -> false
            end;
        _ ->
            false
    end.

reply([], State) ->
    {ok, State};
reply(Msgs, State) ->
    {[{text, s2i_web_json:encode(M)} || M <- Msgs], State}.
