-module(s2i_snmp_mgr).
-moduledoc """
Reconciler of the SNMP side: active configuration ↔ running `s2i_device`
processes under `s2i_devices_sup`.

A device's desired spec is its (enabled) entity, its profile and its
expansion; any change restarts just that device (unregister + register, which
is also the only correct way to change an snmpm agent address, see
`s2i_snmpm_spike_SUITE`). Before devices are started the IEC side is synced,
so that the points exist when the first values arrive.
""".
-behaviour(gen_server).

-export([start_link/0, child_spec/0, sync/0]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2]).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec child_spec() -> supervisor:child_spec().
child_spec() ->
    #{id => ?MODULE, start => {?MODULE, start_link, []}, type => worker}.

-doc "Apply the active configuration now if it has not been applied yet.".
-spec sync() -> ok.
sync() ->
    gen_server:call(?MODULE, sync, 30000).

%%% gen_server

-spec init([]) -> {ok, map(), {continue, reconcile}}.
init([]) ->
    ok = s2i_config:subscribe(),
    %% after a restart of this process alone: start from a clean slate
    _ = [stop_device(Id) || {Id, _, _, _} <- supervisor:which_children(s2i_devices_sup)],
    {ok, #{applied => undefined, running => #{}}, {continue, reconcile}}.

-spec handle_continue(reconcile, map()) -> {noreply, map()}.
handle_continue(reconcile, State) ->
    {noreply, reconcile(State)}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call(sync, _From, State) ->
    {reply, ok, maybe_reconcile(State)};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info({s2i_config, {activated, _Vsn}}, State) ->
    {noreply, maybe_reconcile(State)};
handle_info(_Msg, State) ->
    {noreply, State}.

%%% reconcile

maybe_reconcile(#{applied := Applied} = State) ->
    case s2i_config:active() of
        {ok, Applied, _} -> State;
        {error, none} when Applied =:= none -> State;
        _ -> reconcile(State)
    end.

reconcile(#{running := Running} = State) ->
    {Vsn, Desired} = desired(),
    #{stop := Stop, start := Start} = s2i_reconcile:servers(Desired, Running),
    Running1 = lists:foldl(fun(N, Acc) -> stop_device(N), maps:remove(N, Acc) end, Running, Stop),
    _ = Start =/= [] andalso sync_iec(),
    Running2 = lists:foldl(fun start_device/2, Running1, Start),
    State#{applied := Vsn, running := Running2}.

desired() ->
    case s2i_config:active() of
        {error, none} ->
            {none, #{}};
        {ok, Vsn, #{devices := Devices, profiles := Profiles} = Config} ->
            {ok, Expansions} = s2i_expand:config(Config),
            {Vsn, #{N => #{device => D, profile => maps:get(P, Profiles),
                           expansion => maps:get(N, Expansions)}
                    || N := #{enabled := true, profile := P} = D <- Devices}}
    end.

start_device({Name, Spec}, Running) ->
    case supervisor:start_child(s2i_devices_sup, s2i_device:child_spec(Name, Spec)) of
        {ok, _} ->
            Running#{Name => Spec};
        {error, Reason} ->
            logger:error("SNMP device ~ts failed to start: ~p", [Name, Reason]),
            Running
    end.

stop_device(Name) ->
    _ = supervisor:terminate_child(s2i_devices_sup, Name),
    _ = supervisor:delete_child(s2i_devices_sup, Name),
    ok.

%% The IEC side may not run (e.g. in SNMP-only tests).
sync_iec() ->
    try s2i_iec_mgr:sync()
    catch exit:{noproc, _} -> ok
    end.
