-module(s2i_debug).
-moduledoc """
Debug event fan-out (docs/DESIGN.md §9.3). Every topic is a `pg` group in
the scope `s2i_debug_pg`; subscribers get `{s2i_debug, Topic, Event}` messages.

Topics (binaries): `values:device:<name>`, `values:server:<name>`,
`snmp:trace:<device>`, `traps`, `iec:<server>`, `log`.

- Producers call `publish/2` (or check `active/1` first when building the
  event costs something). Without subscribers this is one ETS lookup.
- `traps`, `log` and `iec:*` are *buffered*: they go through this process,
  which keeps the newest events in a ring buffer (`s2i_core`
  `debug_history`, default 200; `debug_log_history`, default 500) and hands
  them to a new subscriber with `subscribe/1`. They are low-rate topics.
- The others (values, SNMP trace) go straight from the producer to the
  subscribers; a value subscriber gets its snapshot from `s2i_live`.
- `publish/2` never fails, also while this process or the scope is down.

This process installs the `logger` handler `s2i_debug` (`s2i_debug_log`,
level `s2i_core` `debug_log_level`, default `info`) for the `log` topic.
""".
-behaviour(gen_server).

-export([start_link/0, publish/2, active/1, subscribe/1, unsubscribe/1, scope/0]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

-define(SCOPE, s2i_debug_pg).
-define(HANDLER, s2i_debug).

-type topic() :: binary().
-type event() :: #{at := integer(), atom() => term()}.
-export_type([topic/0, event/0]).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "The `pg` scope of the topics.".
-spec scope() -> atom().
scope() -> ?SCOPE.

-doc "Publish `Event` (a map; `at` = now in ms if missing) on `Topic`.".
-spec publish(topic(), map()) -> ok.
publish(Topic, Event0) ->
    Event = case Event0 of
                #{at := _} -> Event0;
                _ -> Event0#{at => os:system_time(millisecond)}
            end,
    case buffered(Topic) of
        true ->
            gen_server:cast(?MODULE, {publish, Topic, Event});
        false ->
            send(members(Topic), Topic, Event)
    end.

-doc "Whether `Topic` has subscribers.".
-spec active(topic()) -> boolean().
active(Topic) ->
    members(Topic) =/= [].

-doc """
Subscribe the calling process to `Topic`; returns the buffered history
(oldest first, empty for unbuffered topics). Subscribing twice is harmless.
""".
-spec subscribe(topic()) -> {ok, [event()]}.
subscribe(Topic) when is_binary(Topic) ->
    gen_server:call(?MODULE, {subscribe, Topic, self()}).

-spec unsubscribe(topic()) -> ok.
unsubscribe(Topic) ->
    _ = pg:leave(?SCOPE, Topic, self()),
    ok.

%%% ===========================================================================
%%% gen_server
%%% ===========================================================================

-spec init([]) -> {ok, map()}.
init([]) ->
    process_flag(trap_exit, true),
    ok = add_log_handler(),
    {ok, #{rings => #{}}}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call({subscribe, Topic, Pid}, _From, #{rings := Rings} = State) ->
    case lists:member(Pid, pg:get_local_members(?SCOPE, Topic)) of
        true -> ok;
        false -> ok = pg:join(?SCOPE, Topic, Pid)
    end,
    History = case Rings of
                  #{Topic := R} -> s2i_debug_ring:to_list(R);
                  _ -> []
              end,
    {reply, {ok, History}, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast({publish, Topic, Event}, #{rings := Rings} = State) ->
    Ring = case Rings of
               #{Topic := R} -> R;
               _ -> s2i_debug_ring:new(history_size(Topic))
           end,
    send(members(Topic), Topic, Event),
    {noreply, State#{rings := Rings#{Topic => s2i_debug_ring:push(Event, Ring)}}};
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec terminate(term(), map()) -> ok.
terminate(_Reason, _State) ->
    _ = logger:remove_handler(?HANDLER),
    ok.

%%% ===========================================================================
%%% Internals
%%% ===========================================================================

buffered(<<"traps">>) -> true;
buffered(<<"log">>) -> true;
buffered(<<"iec:", _/binary>>) -> true;
buffered(_) -> false.

history_size(<<"log">>) -> application:get_env(s2i_core, debug_log_history, 500);
history_size(_) -> application:get_env(s2i_core, debug_history, 200).

members(Topic) ->
    try
        pg:get_members(?SCOPE, Topic)
    catch
        error:badarg -> []                      % scope not running
    end.

send([], _Topic, _Event) ->
    ok;
send(Pids, Topic, Event) ->
    Msg = {s2i_debug, Topic, Event},
    lists:foreach(fun(P) -> P ! Msg end, Pids).

add_log_handler() ->
    _ = logger:remove_handler(?HANDLER),
    Level = application:get_env(s2i_core, debug_log_level, info),
    ok = logger:add_handler(?HANDLER, s2i_debug_log, #{level => Level}).
