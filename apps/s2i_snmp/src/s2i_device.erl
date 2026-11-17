-module(s2i_device).
-moduledoc """
One SNMP device: registration with snmpm, instance resolution, poll cycles,
health and quality (docs/DESIGN.md §5.3, §6, §6.1, §8).

Start-up (`handle_continue(register)`, retried every `?RETRY_MS` on failure):
open the stored secrets, resolve the host, discover the v3 engine id when it
is not configured (`s2i_snmp_discover`), register an snmpm user (data = this
pid), the USM user and the agent. Then resolve instances and start polling.

Requests are asynchronous; snmpm neither retries nor reports a timeout of an
async request, so every request has a timer here and is resent up to
`retries` times. A v3 report (e.g. not in time window after an agent
reboot) resends all outstanding requests once.

Poll groups run on a drift-free schedule; while a group's cycle is still in
flight its next tick is skipped and counted as an overrun. A cycle fails if
one of its chunks fails after all retries. `down_after` consecutive failed
cycles → `down`: all points invalid (last value kept), comm status `false`.
The next successful cycle → `up`, comm status `true`, instances resolved
again; values are republished as they arrive.

Reboot detection: `sysUpTime.0` is in every poll group; a lower value from a
newer request resets the transform states (counter discontinuity) and
resolves the instances again. When the resolution changes, the routes are
rebuilt; points whose instance is lost are invalidated.

Traps and informs (§5.4) arrive from the registered address through the
device's snmpm user, or from another port of the same IP through
`s2i_trap_sources`. `s2i_trap_match` turns them into values for the
device's datapoints; they are published at once and recorded in `trap_at`.
Ordering rule: a polled value whose request was sent before the last trap
of its datapoint is discarded. A rule may reset its datapoint after a delay
(`auto_reset`: one timer per datapoint, restarted by every matching trap)
or schedule a GET of it (`confirm_get_after`). Such one-off GETs (also
used for newly resolved instances, so they need not wait a whole poll
interval) only log failures; they do not count for health. Trap-only datapoints stay invalid until
their first trap, and after `down` until the next one.

SNMPv3: the USM user is registered under the agent's engine id (polling,
traps) and under the gateway's engine id (informs, where the gateway is the
authoritative engine). Devices that share a user name must use the same
passwords for informs: the last registration wins.

Tools (REST, §9.1): `get/2` and `walk/3` send one-off requests through the
device's registration, so no secrets have to be supplied by the caller.
They use the device's timeout and retries and do not count for health.
""".
-behaviour(gen_server).

-export([start_link/2, child_spec/2, status/1, get/2, walk/3]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(RETRY_MS, 10000).
-define(BULK, 25).

-type spec() :: #{device := map(), profile := map(), expansion := s2i_expand:expansion()}.
-type varbind() :: tuple().                     % snmpm #varbind{}
-type tool_error() :: not_running | not_registered | too_many_oids | timeout | term().

-spec child_spec(binary(), spec()) -> supervisor:child_spec().
child_spec(Name, Spec) ->
    #{id => Name, start => {?MODULE, start_link, [Name, Spec]}, restart => permanent,
      shutdown => 5000, type => worker}.

-spec start_link(binary(), spec()) -> gen_server:start_ret().
start_link(Name, Spec) ->
    gen_server:start_link(?MODULE, {Name, Spec}, []).

-doc "Health and counters of a running device.".
-spec status(binary()) -> {ok, map()} | {error, not_running}.
status(Name) ->
    case pid(Name) of
        {ok, Pid} -> {ok, gen_server:call(Pid, status)};
        Error -> Error
    end.

-doc "One GET of `Oids` (at most `max_varbinds`); the varbinds as snmpm returns them.".
-spec get(binary(), [[non_neg_integer()]]) -> {ok, [varbind()]} | {error, tool_error()}.
get(Name, Oids) ->
    tool_call(Name, {tool_get, Oids}).

-doc "Walk the subtree `Root`, stopping after `Max` varbinds (`truncated`).".
-spec walk(binary(), [non_neg_integer()], pos_integer()) ->
          {ok, [varbind()], complete | truncated} | {error, tool_error()}.
walk(Name, Root, Max) ->
    tool_call(Name, {tool_walk, Root, Max}).

tool_call(Name, Req) ->
    case pid(Name) of
        {ok, Pid} ->
            try
                gen_server:call(Pid, Req, 120000)
            catch
                exit:{timeout, _} -> {error, timeout}
            end;
        Error ->
            Error
    end.

pid(Name) ->
    case [Pid || {Id, Pid, _, _} <- supervisor:which_children(s2i_devices_sup),
                 Id =:= Name, is_pid(Pid)] of
        [Pid] -> {ok, Pid};
        [] -> {error, not_running}
    end.

%%% ===========================================================================
%%% gen_server
%%% ===========================================================================

init({Name, #{device := Device, profile := Profile, expansion := Exp}}) ->
    process_flag(trap_exit, true),
    logger:update_process_metadata(#{device => Name}),
    Resolvers = s2i_resolve:columns(Device, Profile),
    State = #{name => Name, device => Device, profile => Profile, exp => Exp,
              user => s2i_snmp_conf:user(Name), target => s2i_snmp_conf:target(Name),
              snmp => undefined, usm => [], registered => false,
              resolvers => Resolvers, resolved => #{}, resolve => idle, walk => undefined,
              routes => s2i_routes:device(Exp, #{}), states => #{},
              rules => s2i_trap_match:compile(maps:get(trap_rules, Profile, [])),
              trap_at => #{}, resets => #{}, traps => 0, unmatched => 0, ip => undefined,
              groups => #{}, reqs => #{},
              health => unknown, failures => 0, comm => undefined, uptime => undefined,
              overruns => 0, cycles => 0, last_ok => undefined, error => undefined},
    {ok, State, {continue, register}}.

handle_continue(register, State) ->
    {noreply, register(State)}.

handle_call(status, _From, State) ->
    Status = maps:with([health, failures, overruns, cycles, last_ok, error, resolved, traps, unmatched,
                        registered], State),
    Unresolved = [Id || #{id := Id} <- maps:get(unresolved, maps:get(routes, State))],
    {reply, Status#{unresolved => Unresolved}, State};
handle_call({tool_get, _}, _From, #{registered := false} = State) ->
    {reply, {error, not_registered}, State};
handle_call({tool_get, Oids}, _From, #{device := #{max_varbinds := Max}} = State)
  when length(Oids) > Max ->
    {reply, {error, too_many_oids}, State};
handle_call({tool_get, Oids}, From, State) ->
    {noreply, send({tool_get, From}, Oids, 0, State)};
handle_call({tool_walk, _, _}, _From, #{registered := false} = State) ->
    {reply, {error, not_registered}, State};
handle_call({tool_walk, Root, Max}, From, State) ->
    {noreply, send({tool_walk, #{from => From, root => Root, max => Max, acc => [], n => 0}},
                   [Root], 0, State)};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(register, #{registered := false} = State) ->
    {noreply, register(State)};
handle_info({timeout, _, {tick, G}}, State) ->
    {noreply, tick(G, State)};
handle_info({timeout, _, {req_timeout, ReqId}}, #{reqs := Reqs} = State) ->
    case maps:take(ReqId, Reqs) of
        {Req, Reqs1} -> {noreply, retry(Req, timeout, State#{reqs := Reqs1})};
        error -> {noreply, State}
    end;
handle_info({snmp_pdu, ReqId, Resp}, #{reqs := Reqs} = State) ->
    case maps:take(ReqId, Reqs) of
        {#{timer := T} = Req, Reqs1} ->
            _ = erlang:cancel_timer(T),
            {noreply, response(Req, Resp, State#{reqs := Reqs1})};
        error ->
            {noreply, State}                    % late answer to a retried request
    end;
handle_info({snmp_error, ReqId, Reason}, #{reqs := Reqs} = State) ->
    case maps:take(ReqId, Reqs) of
        {#{timer := T} = Req, Reqs1} ->
            _ = erlang:cancel_timer(T),
            {noreply, retry(Req, Reason, State#{reqs := Reqs1})};
        error ->
            {noreply, State}
    end;
handle_info({snmp_report, _Info}, State) ->
    {noreply, resend_after_report(State)};
handle_info({snmp_trap, Info}, State) ->
    {noreply, trap(Info, State)};
handle_info({snmp_inform, Info}, State) ->
    {noreply, trap(Info, State)};
handle_info({snmp_trap_from, _Addr, Info}, State) ->
    {noreply, trap(Info, State)};
handle_info({timeout, Ref, {auto_reset, Oid, Value}}, #{resets := Resets} = State) ->
    case Resets of
        #{Oid := Ref} -> {noreply, trap_values([{Oid, Value}], State#{resets := maps:remove(Oid, Resets)})};
        _ -> {noreply, State}
    end;
handle_info({timeout, _, {get_once, Oids}}, State) ->
    {noreply, get_once(Oids, State)};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    deregister(State).

%%% ===========================================================================
%%% Registration
%%% ===========================================================================

register(#{device := #{host := Host, snmp := Sealed, timeout := Timeout, retries := Retries} = Device,
           user := User, target := Target} = State0) ->
    State = deregister(State0),
    maybe
        {ok, Snmp} ?= open_secrets(Sealed),
        {ok, Ip} ?= resolve_host(Host),
        {ok, EngineId} ?= engine_id(Snmp, Ip, maps:get(port, Device), Timeout, Retries),
        ok ?= snmpm:register_user(User, s2i_snmpm_user, self()),
        {ok, Usm} ?= register_usm(Snmp, EngineId),
        ok ?= snmpm:register_agent(User, Target, s2i_snmp_conf:agent(Device#{snmp := Snmp}, Ip, EngineId)),
        ok = s2i_trap_sources:add(Ip),
        logger:info("SNMP device ~ts registered (~ts)", [maps:get(name, State), inet:ntoa(Ip)]),
        start_polling(State#{registered := true, usm := Usm, snmp := Snmp, ip := Ip, error := undefined})
    else
        {error, Reason} ->
            logger:warning("SNMP device ~ts not registered: ~p; retrying", [maps:get(name, State), Reason]),
            _ = erlang:send_after(?RETRY_MS, self(), register),
            failed_cycle(deregister(State#{error := Reason}))
    end.

deregister(#{user := User, target := Target, usm := Usm, ip := Ip} = State) ->
    _ = Ip =/= undefined andalso s2i_trap_sources:remove(Ip),
    _ = catch snmpm:unregister_agent(User, Target),
    _ = catch snmpm:unregister_user(User),
    _ = [catch snmpm:unregister_usm_user(E, U) || {E, U} <- Usm],
    State#{registered := false, usm := [], ip := undefined}.

open_secrets(#{version := v3} = Snmp) ->
    open_fields([auth_password, priv_password], Snmp);
open_secrets(Snmp) ->
    open_fields([community], Snmp).

open_fields(Fields, Snmp) ->
    lists:foldl(fun(F, {ok, Acc}) ->
                        case Acc of
                            #{F := Sealed} ->
                                case s2i_secret:open(Sealed) of
                                    {ok, Plain} -> {ok, Acc#{F := Plain}};
                                    {error, R} -> {error, {secret, F, R}}
                                end;
                            _ ->
                                {ok, Acc}
                        end;
                   (_, Error) ->
                        Error
                end, {ok, Snmp}, Fields).

resolve_host(Host) ->
    case inet:getaddr(binary_to_list(Host), inet) of
        {ok, Ip} -> {ok, Ip};
        {error, R} -> {error, {host, R}}
    end.

engine_id(#{version := v3, engine_id := Hex}, _Ip, _Port, _Timeout, _Retries) ->
    {ok, s2i_snmp_conf:engine_id(Hex)};
engine_id(#{version := v3}, Ip, Port, Timeout, Retries) ->
    case s2i_snmp_discover:engine_id(Ip, Port, Timeout, Retries) of
        {ok, E} -> {ok, E};
        {error, R} -> {error, {engine_id_discovery, R}}
    end;
engine_id(_Snmp, _Ip, _Port, _Timeout, _Retries) ->
    {ok, undefined}.

%% Under the agent's engine id (requests, traps) and the gateway's (informs).
%% A leftover registration (failed earlier attempt, other device with the
%% same user name) is replaced.
register_usm(#{version := v3} = Snmp, EngineId) ->
    lists:foldl(fun(Engine, {ok, Acc}) ->
                        {E, U, Conf} = s2i_snmp_conf:usm(Snmp, Engine),
                        _ = snmpm:unregister_usm_user(E, U),
                        case snmpm:register_usm_user(E, U, Conf) of
                            ok -> {ok, [{E, U} | Acc]};
                            {error, R} -> {error, {usm, R}}
                        end;
                   (_, Error) ->
                        Error
                end, {ok, []}, lists:usort([EngineId, s2i_snmpm:local_engine_id()]));
register_usm(_Snmp, _EngineId) ->
    {ok, []}.

%%% ===========================================================================
%%% Poll groups
%%% ===========================================================================

start_polling(State) ->
    rebuild_groups(start_resolve(State)).

%% (Re)build the groups from the current routes. Running groups keep their
%% schedule; new groups start now; vanished groups are dropped.
rebuild_groups(#{routes := #{polls := Polls}, profile := #{poll_groups := Intervals},
                 device := #{max_varbinds := Max}, groups := Old} = State) ->
    Now = now_ms(),
    Groups = maps:map(
               fun(G, Oids) ->
                       Chunks = s2i_poll:chunks(Oids, Max),
                       case Old of
                           #{G := Grp} -> Grp#{chunks := Chunks};
                           _ -> schedule(G, #{interval => maps:get(G, Intervals), deadline => Now,
                                              chunks => Chunks, pending => 0, failed => false,
                                              timer => undefined})
                       end
               end, Polls),
    _ = [erlang:cancel_timer(T) || G := #{timer := T} <- Old, not is_map_key(G, Groups), T =/= undefined],
    State#{groups := Groups}.

schedule(G, #{deadline := D} = Grp) ->
    Grp#{timer := erlang:start_timer(D, self(), {tick, G}, [{abs, true}])}.

tick(G, #{groups := Groups, registered := true} = State) ->
    case Groups of
        #{G := #{interval := I, deadline := D, pending := P, chunks := Chunks} = Grp} ->
            {Next, Missed} = s2i_poll:next_deadline(D, I, now_ms()),
            Grp1 = schedule(G, Grp#{deadline := Next}),
            State1 = State#{overruns := maps:get(overruns, State) + Missed},
            case P of
                0 ->
                    State2 = State1#{groups := Groups#{G := Grp1#{pending := length(Chunks), failed := false}}},
                    lists:foldl(fun(C, S) -> send({poll, G}, C, 0, S) end, State2, Chunks);
                _ ->
                    %% previous cycle still running
                    State1#{groups := Groups#{G := Grp1}, overruns := maps:get(overruns, State1) + 1}
            end;
        _ ->
            State
    end;
tick(_G, State) ->
    State.

%%% ===========================================================================
%%% Requests
%%% ===========================================================================

send(Kind, Oids, Attempt, State) ->
    send(Kind, Oids, Attempt, false, State).

send(Kind, Oids, Attempt, Reported, #{user := User, target := Target, reqs := Reqs,
                                      device := #{timeout := Timeout, snmp := #{version := Vsn}}} = State) ->
    Opts = [{timeout, Timeout + 1000}],         % snmpm's own clean-up only
    Result = case Kind of
                 {W, _} when (W =:= walk orelse W =:= tool_walk), Vsn =:= v1 ->
                     snmpm:async_get_next2(User, Target, Oids, Opts);
                 {W, _} when W =:= walk; W =:= tool_walk ->
                     snmpm:async_get_bulk2(User, Target, 0, ?BULK, Oids, Opts);
                 _ ->
                     snmpm:async_get2(User, Target, Oids, Opts)  % poll, once, tool_get
             end,
    Req = #{kind => Kind, oids => Oids, attempt => Attempt, reported => Reported, sent_at => now_ms()},
    case Result of
        {ok, ReqId} ->
            T = erlang:start_timer(Timeout, self(), {req_timeout, ReqId}),
            State#{reqs := Reqs#{ReqId => Req#{timer => T}}};
        {error, Reason} ->
            failed(Req, Reason, State)
    end.

retry(#{kind := Kind, oids := Oids, attempt := A} = Req, Reason,
      #{device := #{retries := Retries}} = State) ->
    case A < Retries of
        true -> send(Kind, Oids, A + 1, State);
        false -> failed(Req, Reason, State)
    end.

resend_after_report(#{reqs := Reqs} = State) ->
    {Resend, Keep} = maps:fold(fun(Id, #{reported := false} = R, {Rs, K}) -> {[{Id, R} | Rs], K};
                                  (Id, R, {Rs, K}) -> {Rs, K#{Id => R}}
                               end, {[], #{}}, Reqs),
    lists:foldl(fun({_, #{kind := K, oids := O, attempt := A, timer := T}}, S) ->
                        _ = erlang:cancel_timer(T),
                        send(K, O, A, true, S)
                end, State#{reqs := Keep}, Resend).

failed(#{kind := {poll, G}, oids := Oids}, Reason, State) ->
    logger:debug("SNMP poll of ~p failed: ~p", [Oids, Reason]),
    chunk_done(G, false, State);
failed(#{kind := once, oids := Oids}, Reason, State) ->
    logger:debug("SNMP GET of ~p failed: ~p", [Oids, Reason]),
    State;
failed(#{kind := {walk, R}}, Reason, State) ->
    logger:warning("SNMP walk of resolver ~ts failed: ~p", [R, Reason]),
    State#{walk := undefined, resolve := wanted};
failed(#{kind := {tool_get, From}}, Reason, State) ->
    gen_server:reply(From, {error, Reason}),
    State;
failed(#{kind := {tool_walk, #{from := From}}}, Reason, State) ->
    gen_server:reply(From, {error, Reason}),
    State.

response(#{kind := {poll, G}} = Req, Resp, State) ->
    poll_response(G, Req, Resp, State);
response(#{kind := {walk, R}} = Req, Resp, State) ->
    walk_response(R, Req, Resp, State);
response(#{kind := once, sent_at := SentAt}, {noError, _, Vbs}, State) ->
    apply_varbinds(Vbs, SentAt, State);
response(#{kind := once, oids := Oids}, {Error, _, _}, State) ->
    logger:debug("SNMP GET of ~p answered with ~p", [Oids, Error]),
    State;
response(#{kind := {tool_get, From}}, {noError, _, Vbs}, State) ->
    gen_server:reply(From, {ok, Vbs}),
    State;
response(#{kind := {tool_get, From}}, {Error, Idx, _}, State) ->
    gen_server:reply(From, {error, {Error, Idx}}),
    State;
response(#{kind := {tool_walk, W}}, Resp, State) ->
    tool_walk_response(W, Resp, State).

%% Same end conditions as the resolver walk: a varbind outside the subtree,
%% endOfMibView ('NULL'), or noSuchName on SNMPv1.
tool_walk_response(#{from := From, root := Root, max := Max, acc := Acc, n := N} = W,
                   {noError, _, Vbs}, State) ->
    In = lists:takewhile(fun({varbind, Oid, Type, _, _}) -> lists:prefix(Root, Oid) andalso Type =/= 'NULL' end,
                         Vbs),
    Taken = lists:sublist(In, Max - N),
    Acc1 = lists:reverse(Taken, Acc),
    N1 = N + length(Taken),
    if
        N1 >= Max, In =/= [] ->
            gen_server:reply(From, {ok, lists:reverse(Acc1), truncated}),
            State;
        length(In) =:= length(Vbs), In =/= [] ->
            {varbind, Last, _, _, _} = lists:last(In),
            send({tool_walk, W#{acc := Acc1, n := N1}}, [Last], 0, State);
        true ->
            gen_server:reply(From, {ok, lists:reverse(Acc1), complete}),
            State
    end;
tool_walk_response(#{from := From, acc := Acc}, {noSuchName, _, _}, State) ->
    gen_server:reply(From, {ok, lists:reverse(Acc), complete}),
    State;
tool_walk_response(#{from := From}, {Error, Idx, _}, State) ->
    gen_server:reply(From, {error, {Error, Idx}}),
    State.

%%% ===========================================================================
%%% Poll responses
%%% ===========================================================================

poll_response(G, #{sent_at := SentAt}, {noError, _, Vbs}, State) ->
    chunk_done(G, true, apply_varbinds(Vbs, SentAt, State));
poll_response(G, #{oids := Oids, attempt := A, sent_at := SentAt}, {noSuchName, Idx, _}, State)
  when Idx >= 1, Idx =< length(Oids) ->
    %% SNMPv1: one missing OID fails the whole PDU; mark it and ask again
    %% for the rest within the same cycle
    Bad = lists:nth(Idx, Oids),
    State1 = apply_values([{Bad, no_such_object}], SentAt, State),
    case lists:delete(Bad, Oids) of
        [] -> chunk_done(G, true, State1);
        Rest -> send({poll, G}, Rest, A, State1)
    end;
poll_response(G, #{oids := Oids, sent_at := SentAt}, {Error, _, _}, State) ->
    logger:warning("SNMP poll answered with ~p", [Error]),
    chunk_done(G, true, apply_values([{O, {error, Error}} || O <- Oids], SentAt, State)).

apply_varbinds(Vbs, SentAt, State) ->
    apply_values([{Oid, s2i_poll:value(Type, Value)} || {varbind, Oid, Type, Value, _} <- Vbs],
                 SentAt, State).

apply_values(Values, SentAt, State0) ->
    Uptime = s2i_routes:sys_uptime(),
    State = case lists:keyfind(Uptime, 1, Values) of
                {_, {timeticks, U}} -> uptime({U, SentAt}, State0);
                _ -> State0
            end,
    #{trap_at := TrapAt} = State,
    %% ordering rule: a request sent before the last trap of a datapoint
    %% carries an older state than the trap
    publish_values([V || {Oid, _} = V <- Values, s2i_trap_match:poll_applies(Oid, SentAt, TrapAt)], State).

publish_values(Values, #{routes := #{routes := Routes}, states := States} = State) ->
    Ctx = #{now => now_ms(), ts => os:system_time(millisecond)},
    {Writes, States1} =
        lists:foldl(fun({Oid, V}, {Ws, Sts}) ->
                            case Routes of
                                #{Oid := Rs} ->
                                    {W, Sts1} = s2i_sample:apply(Rs, V, Ctx, Sts),
                                    {Ws ++ W, Sts1};
                                _ ->
                                    {Ws, Sts}
                            end
                    end, {[], States}, Values),
    publish(Writes),
    State#{states := States1}.

uptime(Sample, #{uptime := Prev, states := States, name := Name} = State) ->
    case s2i_poll:uptime(Prev, Sample) of
        {ok, New} ->
            State#{uptime := New};
        {rebooted, New} ->
            logger:notice("SNMP device ~ts rebooted", [Name]),
            start_resolve(State#{uptime := New, states := s2i_sample:reset(States)})
    end.

chunk_done(G, Ok, #{groups := Groups} = State) ->
    case Groups of
        #{G := #{pending := P, failed := F} = Grp} when P > 0 ->
            Grp1 = Grp#{pending := P - 1, failed := F orelse not Ok},
            State1 = State#{groups := Groups#{G := Grp1}},
            case Grp1 of
                #{pending := 0, failed := false} -> ok_cycle(State1);
                #{pending := 0, failed := true} -> failed_cycle(State1);
                _ -> State1
            end;
        _ ->
            State
    end.

%%% ===========================================================================
%%% Traps and informs
%%% ===========================================================================

trap(Info, #{rules := Rules, routes := Routes, name := Name, traps := N} = State0) ->
    State = State0#{traps := N + 1},
    #{trap_oid := TrapOid} = Trap = s2i_trap_match:normalize(Info),
    {Actions, Misses} = s2i_trap_match:match(Trap, Rules, Routes),
    [logger:debug("SNMP device ~ts: trap rule ~ts matched, but found ~p", [Name, R, Why])
     || {R, Why} <- Misses],
    case Actions of
        [] ->
            logger:debug("SNMP device ~ts: unmatched trap ~p", [Name, TrapOid]),
            State#{unmatched := maps:get(unmatched, State) + 1};
        _ ->
            after_trap(Actions, trap_values([{O, V} || #{oid := O, value := V} <- Actions], State))
    end.

trap_values(Values, #{trap_at := TrapAt} = State) ->
    Now = now_ms(),
    publish_values(Values, State#{trap_at := maps:merge(TrapAt, #{O => Now || {O, _} <- Values})}).

after_trap(Actions, #{resets := Resets0} = State) ->
    Resets = lists:foldl(
               fun(#{oid := O, auto_reset := #{delay := D, value := V}}, Acc) ->
                       _ = case Acc of
                               #{O := Old} -> erlang:cancel_timer(Old);
                               _ -> ok
                           end,
                       Acc#{O => erlang:start_timer(D, self(), {auto_reset, O, V})};
                  (_, Acc) ->
                       Acc
               end, Resets0, Actions),
    Confirms = maps:groups_from_list(fun(#{confirm_get_after := D}) -> D end, fun(#{oid := O}) -> O end,
                                     [A || #{confirm_get_after := _} = A <- Actions]),
    maps:foreach(fun(D, Oids) -> erlang:start_timer(D, self(), {get_once, lists:usort(Oids)}) end,
                 Confirms),
    State#{resets := Resets}.

%% A GET outside the poll schedule (trap confirmation, newly resolved
%% instances): applied like a poll response, failures do not count for health.
get_once(Oids, #{registered := true, routes := #{routes := Routes}, device := #{max_varbinds := Max}} = State) ->
    Chunks = s2i_poll:chunks([O || O <- Oids, is_map_key(O, Routes)], Max),
    lists:foldl(fun(C, S) -> send(once, C, 0, S) end, State, Chunks);
get_once(_Oids, State) ->
    State.

%%% ===========================================================================
%%% Health
%%% ===========================================================================

ok_cycle(#{health := Old, resolve := Resolve} = State) ->
    State1 = health(Old, up, State#{failures := 0, cycles := maps:get(cycles, State) + 1,
                                    last_ok := os:system_time(millisecond)}),
    case Resolve of
        wanted -> start_resolve(State1);
        _ -> State1
    end.

failed_cycle(#{failures := F, health := Old, device := #{down_after := N}} = State) ->
    health(Old, s2i_poll:health(F + 1, N), State#{failures := F + 1,
                                                  cycles := maps:get(cycles, State) + 1}).

health(down, down, State) ->
    State;
health(_Old, down, #{name := Name, routes := #{routes := Routes}, states := States} = State) ->
    logger:warning("SNMP device ~ts is down", [Name]),
    {Writes, States1} = s2i_sample:invalidate(lists:append(maps:values(Routes)), States),
    publish(Writes),
    comm_status(false, State#{health := down, states := States1});
health(down, up, #{name := Name} = State) ->
    logger:notice("SNMP device ~ts is up again", [Name]),
    %% the device may have been replaced or renumbered meanwhile
    comm_status(true, start_resolve(State#{health := up}));
health(_Old, up, State) ->
    comm_status(true, State#{health := up});
health(_Old, degraded, State) ->
    %% not down yet: values and comm status stay as they are
    State#{health := degraded}.

comm_status(Value, #{comm := Value} = State) ->
    State;
comm_status(Value, #{routes := #{comm_status := #{server := S, coa := C, ioa := I, type := T}}} = State) ->
    Spec = #{type => T, value => Value, quality => []},
    ok = s2i_iec:publish(S, [{{C, I}, case T of
                                          m_sp_tb_1 -> Spec#{ts => os:system_time(millisecond)};
                                          _ -> Spec
                                      end}]),
    State#{comm := Value};
comm_status(_Value, State) ->
    State.

%%% ===========================================================================
%%% Instance resolution
%%% ===========================================================================

start_resolve(#{resolvers := Rs} = State) when map_size(Rs) =:= 0 ->
    State#{resolve := idle};
start_resolve(#{walk := undefined, registered := true, resolvers := Rs} = State) ->
    [R | Rest] = maps:keys(Rs),
    walk_resolver(R, maps:get(R, Rs), State#{walk := #{todo => Rest, rows => [], acc => #{}}, resolve := running});
start_resolve(#{registered := true} = State) ->
    %% a walk is running: walk again when it is done
    State#{resolve := wanted};
start_resolve(State) ->
    State.

walk_resolver(R, From, State) ->
    send({walk, R}, [From], 0, State).

walk_response(R, _Req, {noError, _, Vbs}, #{resolvers := Rs, walk := #{rows := Rows} = W} = State) ->
    Column = maps:get(R, Rs),
    {In, Done} = lists:foldl(
                   fun({varbind, Oid, Type, Value, _}, {Acc, false}) ->
                           case lists:prefix(Column, Oid) andalso Type =/= 'NULL' of
                               true -> {[{Oid, Value} | Acc], false};
                               false -> {Acc, true}
                           end;
                      (_, {Acc, true}) ->
                           {Acc, true}
                   end, {[], false}, Vbs),
    W1 = W#{rows := lists:reverse(In) ++ Rows},
    case {Done, In} of
        {false, [{Last, _} | _]} -> walk_resolver(R, Last, State#{walk := W1});
        _ -> walk_done(R, State#{walk := W1})
    end;
walk_response(R, _Req, {noSuchName, _, _}, State) ->
    %% SNMPv1 end of MIB view
    walk_done(R, State);
walk_response(R, _Req, {Error, _, _}, State) ->
    logger:warning("SNMP walk of resolver ~ts answered with ~p", [R, Error]),
    State#{walk := undefined, resolve := wanted}.

walk_done(R, #{resolvers := Rs, walk := #{todo := Todo, rows := Rows, acc := Acc}, name := Name} = State) ->
    {Map, Ambiguous} = s2i_resolve:build(maps:get(R, Rs), Rows),
    Ambiguous =/= [] andalso
        logger:warning("SNMP device ~ts: ambiguous ~ts values ~p are not resolved", [Name, R, Ambiguous]),
    Acc1 = Acc#{R => Map},
    case Todo of
        [Next | Rest] ->
            walk_resolver(Next, maps:get(Next, Rs), State#{walk := #{todo => Rest, rows => [], acc => Acc1}});
        [] ->
            resolved(Acc1, State#{walk := undefined})
    end.

resolved(Resolved, #{resolve := Resolve, exp := Exp, routes := Old, states := States, name := Name} = State) ->
    New = s2i_routes:device(Exp, Resolved),
    [logger:warning("SNMP device ~ts: instance of ~ts not found", [Name, Id])
     || #{id := Id} <- maps:get(unresolved, New)],
    OldOids = key_oids(Old),
    NewOids = key_oids(New),
    %% moved instance: other counter, forget the transform state;
    %% lost instance: invalid
    Moved = [K || K := Oid <- OldOids, maps:get(K, NewOids, Oid) =/= Oid],
    Lost = [R || _ := Rs <- maps:get(routes, Old), R <- Rs, not is_map_key(key(R), NewOids)],
    States1 = lists:foldl(fun(K, Acc) ->
                                  case Acc of
                                      #{K := St} -> Acc#{K := St#{t := undefined}};
                                      _ -> Acc
                                  end
                          end, States, Moved),
    {Writes, States2} = s2i_sample:invalidate(Lost, States1),
    publish(Writes),
    %% newly resolved datapoints are read now, not one poll interval later
    Added = lists:usort(lists:append(maps:values(maps:get(polls, New))))
        -- lists:append(maps:values(maps:get(polls, Old))),
    State1 = get_once(Added, rebuild_groups(State#{resolved := Resolved, routes := New, states := States2,
                                                   resolve := idle})),
    case Resolve of
        wanted -> start_resolve(State1);
        _ -> State1
    end.

key_oids(#{routes := Routes}) ->
    #{key(R) => Oid || Oid := Rs <- Routes, R <- Rs}.

key(#{server := S, coa := C, ioa := I}) -> {S, C, I}.

%%% ===========================================================================
%%% helpers
%%% ===========================================================================

publish([]) ->
    ok;
publish(Writes) ->
    maps:foreach(fun(S, {Good, Bad}) ->
                         Good =/= [] andalso s2i_iec:publish(S, Good),
                         Bad =/= [] andalso s2i_iec:invalidate(S, Bad)
                 end, s2i_sample:by_server(Writes)).

now_ms() ->
    erlang:monotonic_time(millisecond).
