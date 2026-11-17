-module(s2i_iec_mgr).
-moduledoc """
Reconciler of the IEC side: active configuration ↔ running erl60870 servers
and the point set in `s2i_live`.

On every activation (and on start), with the diffs from `s2i_reconcile`:

1. stop removed and changed servers (all stops before any start),
2. update `s2i_live`: remove dropped points, add new ones as invalid seeds,
3. start new and changed servers (`s2i_iec_dm` seeds them from `s2i_live`),
4. on servers that kept running: `remove/2` dropped points and `update/2` the
   new seeds (spontaneous, so the SCADA sees them as invalid at once),
5. (re)arm background-scan timers.

A server that fails to start (e.g. port in use) is retried every
`?RETRY_MS`. On start the manager stops any `{s2i, _}` servers left over from
a previous instance, so its view of what runs is always accurate.
""".
-behaviour(gen_server).

-export([start_link/0, child_spec/0, sync/0, status/0]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(RETRY_MS, 2000).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec child_spec() -> supervisor:child_spec().
child_spec() ->
    #{id => ?MODULE, start => {?MODULE, start_link, []}, type => worker, shutdown => 10000}.

-doc "Apply the active configuration now if it has not been applied yet.".
-spec sync() -> ok.
sync() ->
    gen_server:call(?MODULE, sync, 30000).

-doc "State of every configured server: `running` or `start_failed` (retried).".
-spec status() -> #{binary() => running | start_failed}.
status() ->
    gen_server:call(?MODULE, status).

%%% ===========================================================================
%%% gen_server
%%% ===========================================================================

-spec init([]) -> {ok, map(), {continue, reconcile}}.
init([]) ->
    process_flag(trap_exit, true),
    ok = s2i_config:subscribe(),
    _ = [iec60870:stop_server(N) || {{s2i, _} = N, _} <- iec60870:which_servers()],
    {ok, #{applied => undefined, servers => #{}, failed => [], scans => #{}, retry => undefined},
     {continue, reconcile}}.

-spec handle_continue(reconcile, map()) -> {noreply, map()}.
handle_continue(reconcile, State) ->
    {noreply, reconcile(State)}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call(sync, _From, State) ->
    {reply, ok, maybe_reconcile(State)};
handle_call(status, _From, #{servers := Running, failed := Failed} = State) ->
    {reply, maps:merge(#{N => start_failed || N <- Failed}, #{N => running || N := _ <- Running}), State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info({s2i_config, {activated, _Vsn}}, State) ->
    {noreply, maybe_reconcile(State)};
handle_info(retry, State) ->
    {noreply, reconcile(State#{retry := undefined})};
handle_info({scan, Server}, State) ->
    background_scan(Server),
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

-spec terminate(term(), map()) -> ok.
terminate(_Reason, #{servers := Servers}) ->
    _ = [iec60870:stop_server(s2i_iec_config:name(N)) || N <- maps:keys(Servers)],
    ok.

%%% ===========================================================================
%%% Reconcile
%%% ===========================================================================

maybe_reconcile(#{applied := Applied} = State) ->
    case active_vsn() of
        Applied -> State;
        _ -> reconcile(State)
    end.

active_vsn() ->
    case s2i_config:active() of
        {ok, Vsn, _} -> Vsn;
        {error, none} -> none
    end.

reconcile(#{servers := Running} = State) ->
    {Vsn, Entities, Points} = desired(),
    Desired = maps:map(fun(_, E) -> s2i_iec_config:server(E) end, Entities),
    #{stop := Stop, start := Start} = s2i_reconcile:servers(Desired, Running),
    #{remove := Remove, add := Add} = s2i_reconcile:points(s2i_live:points(), Points),

    Running1 = lists:foldl(fun(N, Acc) ->
                                   ok = iec60870:stop_server(s2i_iec_config:name(N)),
                                   maps:remove(N, Acc)
                           end, Running, Stop),
    _ = [s2i_live:remove(S, A) || {S, A} <- Remove],
    _ = [s2i_live:add(S, A, P, s2i_iec_config:seed(maps:get(type, P))) || {S, A, P} <- Add],
    {Running2, Failed} = lists:foldl(fun start_server/2, {Running1, []}, Start),

    Untouched = maps:without([N || {N, _} <- Start], Running2),
    _ = [remove_points(S, [A || {S1, A} <- Remove, S1 =:= S]) || S <- maps:keys(Untouched)],
    _ = [s2i_iec:publish(S, [{A, s2i_live_seed(S, A)} || {S1, A, _} <- Add, S1 =:= S])
         || S <- maps:keys(Untouched)],

    State1 = State#{applied := Vsn, servers := Running2, failed := Failed,
                    scans := scans(Entities, Running2, maps:get(scans, State))},
    retry_later(Failed, State1).

desired() ->
    case s2i_config:active() of
        {error, none} ->
            {none, #{}, #{}};
        {ok, Vsn, #{servers := Servers} = Config} ->
            {ok, Expansions} = s2i_expand:config(Config),
            {Vsn, Servers, s2i_routes:points(Expansions)}
    end.

start_server({Name, Spec}, {Running, Failed}) ->
    case iec60870:start_server(s2i_iec_config:name(Name), Spec) of
        {ok, _} ->
            logger:info("IEC 104 server ~ts started", [Name]),
            {Running#{Name => Spec}, Failed};
        {error, Reason} ->
            logger:error("IEC 104 server ~ts failed to start: ~p", [Name, Reason]),
            {Running, [Name | Failed]}
    end.

remove_points(_Server, []) -> ok;
remove_points(Server, Addrs) -> iec60870_server:remove(s2i_iec_config:ref(Server), Addrs).

s2i_live_seed(Server, Addr) ->
    {ok, Spec} = s2i_live:get(Server, Addr),
    Spec.

retry_later([], State) ->
    State;
retry_later(_Failed, #{retry := undefined} = State) ->
    State#{retry := erlang:send_after(?RETRY_MS, self(), retry)};
retry_later(_Failed, State) ->
    State.

%%% ---------------------------------------------------------------------------
%%% Background scan
%%% ---------------------------------------------------------------------------

%% One interval timer per running server with `background_scan`; re-armed on
%% every reconcile.
scans(Entities, Running, Old) ->
    _ = [timer:cancel(T) || T <- maps:values(Old)],
    maps:from_list(
      [{N, T} || N := #{background_scan := Ms} <- maps:iterator(Entities, ordered),
                 is_map_key(N, Running),
                 {ok, T} <- [timer:send_interval(Ms, {scan, N})]]).

background_scan(Server) ->
    case s2i_live:values(Server) of
        [] -> ok;
        Values ->
            try
                iec60870_server:update(s2i_iec_config:ref(Server),
                                       [{A, Spec#{cot => background}} || {A, Spec} <- Values])
            catch
                error:Reason when Reason =:= unknown_server; Reason =:= server_not_ready -> ok
            end
    end.
