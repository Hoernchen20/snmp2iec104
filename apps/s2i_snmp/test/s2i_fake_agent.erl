-module(s2i_fake_agent).
-moduledoc """
Scripted SNMP v1/v2c agent for common_test: GET, GETNEXT and GETBULK over a
MIB the test controls (`set/3`, `delete/2`), community `public`.

- `sysUpTime.0` runs from the agent start; `reboot/1` restarts it at 0.
- `silent/2` drops all requests (device down), `requests/1` counts PDUs.
- v1 errors (`noSuchName`) and v2c exceptions (`noSuchInstance`,
  `endOfMibView`) as a real agent sends them.
""".
-behaviour(gen_server).

%% the records of the OTP header are untyped
-compile(nowarn_untyped_record).
-define(SNMP_USE_V3, true).
-include_lib("snmp/include/snmp_types.hrl").

-export([start/0, stop/1, port/1, set/3, delete/2, reboot/1, silent/2, requests/1, gets/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(UPTIME, [1, 3, 6, 1, 2, 1, 1, 3, 0]).

start() ->
    gen_server:start(?MODULE, [], []).

stop(Pid) ->
    gen_server:stop(Pid).

port(Pid) -> gen_server:call(Pid, port).

-doc "Set `Oid` to `{Type, Value}` (snmp types, e.g. `{'INTEGER', 3}`).".
set(Pid, Oid, TypedValue) -> gen_server:call(Pid, {set, Oid, TypedValue}).

delete(Pid, Oid) -> gen_server:call(Pid, {delete, Oid}).

reboot(Pid) -> gen_server:call(Pid, reboot).

silent(Pid, Bool) -> gen_server:call(Pid, {silent, Bool}).

requests(Pid) -> gen_server:call(Pid, requests).

-doc "The OID lists of all GET requests received so far.".
gets(Pid) -> gen_server:call(Pid, gets).

%%% gen_server

init([]) ->
    {ok, Sock} = gen_udp:open(0, [binary, {ip, {127, 0, 0, 1}}, {active, true}]),
    {ok, #{sock => Sock, mib => gb_trees:empty(), boot => now_ms(), silent => false,
           requests => 0, gets => []}}.

handle_call(port, _From, #{sock := S} = St) ->
    {ok, P} = inet:port(S),
    {reply, P, St};
handle_call({set, Oid, TV}, _From, #{mib := Mib} = St) ->
    {reply, ok, St#{mib := gb_trees:enter(Oid, TV, Mib)}};
handle_call({delete, Oid}, _From, #{mib := Mib} = St) ->
    {reply, ok, St#{mib := gb_trees:delete_any(Oid, Mib)}};
handle_call(reboot, _From, St) ->
    {reply, ok, St#{boot := now_ms()}};
handle_call({silent, B}, _From, St) ->
    {reply, ok, St#{silent := B}};
handle_call(requests, _From, #{requests := N} = St) ->
    {reply, N, St};
handle_call(gets, _From, #{gets := G} = St) ->
    {reply, lists:reverse(G), St}.

handle_cast(_Msg, St) ->
    {noreply, St}.

handle_info({udp, Sock, Ip, Port, Packet}, #{requests := N} = St0) ->
    St = St0#{requests := N + 1},
    case St of
        #{silent := true} ->
            {noreply, St};
        _ ->
            try snmp_pdus:dec_message(binary_to_list(Packet)) of
                #message{version = V, vsn_hdr = "public", data = #pdu{} = Pdu} = Msg ->
                    {Resp, St1} = respond(V, Pdu, St),
                    Bin = snmp_pdus:enc_message(Msg#message{data = Resp}),
                    ok = gen_udp:send(Sock, Ip, Port, Bin),
                    {noreply, St1};
                _ ->
                    {noreply, St}
            catch _:_ ->
                    {noreply, St}
            end
    end;
handle_info(_Msg, St) ->
    {noreply, St}.

%%% PDUs

respond(V, #pdu{type = 'get-request', varbinds = Vbs} = Pdu, #{gets := G} = St) ->
    Oids = [O || #varbind{oid = O} <- Vbs],
    Found = [{O, lookup(O, St)} || O <- Oids],
    Resp = case {V, first_missing(Found)} of
               {'version-1', {ok, Idx}} -> error_pdu(Pdu, noSuchName, Idx);
               {_, _} -> ok_pdu(Pdu, [vb(O, TV, noSuchInstance) || {O, TV} <- Found])
           end,
    {Resp, St#{gets := [Oids | G]}};
respond(V, #pdu{type = 'get-next-request', varbinds = Vbs} = Pdu, St) ->
    Next = [next(O, St) || #varbind{oid = O} <- Vbs],
    Resp = case {V, first_missing(Next)} of
               {'version-1', {ok, Idx}} -> error_pdu(Pdu, noSuchName, Idx);
               {_, _} -> ok_pdu(Pdu, [vb(O, TV, endOfMibView) || {O, TV} <- Next])
           end,
    {Resp, St};
respond(_V, #pdu{type = 'get-bulk-request', error_index = MaxRep, varbinds = Vbs} = Pdu, St) ->
    Rows = bulk([O || #varbind{oid = O} <- Vbs], MaxRep, St),
    {ok_pdu(Pdu, [vb(O, TV, endOfMibView) || {O, TV} <- Rows]), St}.

bulk(_Oids, 0, _St) ->
    [];
bulk(Oids, N, St) ->
    Next = [next(O, St) || O <- Oids],
    case [O || {O, {ok, _}} <- Next] of
        [] -> Next;
        More when length(More) =:= length(Oids) -> Next ++ bulk(More, N - 1, St);
        _ -> Next
    end.

lookup(?UPTIME, #{boot := Boot}) ->
    {ok, {'TimeTicks', (now_ms() - Boot) div 10}};
lookup(Oid, #{mib := Mib}) ->
    case gb_trees:lookup(Oid, Mib) of
        {value, TV} -> {ok, TV};
        none -> none
    end.

next(Oid, #{mib := Mib} = St) ->
    Keys = lists:usort([?UPTIME | gb_trees:keys(Mib)]),
    case [K || K <- Keys, K > Oid] of
        [K | _] -> {K, lookup(K, St)};
        [] -> {Oid, none}
    end.

first_missing(Found) ->
    case [I || {I, {_, none}} <- lists:zip(lists:seq(1, length(Found)), Found)] of
        [I | _] -> {ok, I};
        [] -> none
    end.

vb(Oid, {ok, {Type, Value}}, _Exception) ->
    #varbind{oid = Oid, variabletype = Type, value = Value};
vb(Oid, none, Exception) ->
    #varbind{oid = Oid, variabletype = 'NULL', value = Exception}.

ok_pdu(Pdu, Vbs) ->
    Pdu#pdu{type = 'get-response', error_status = noError, error_index = 0,
            varbinds = [Vb#varbind{org_index = I} || {I, Vb} <- lists:zip(lists:seq(1, length(Vbs)), Vbs)]}.

error_pdu(#pdu{varbinds = Vbs} = Pdu, Status, Idx) ->
    Pdu#pdu{type = 'get-response', error_status = Status, error_index = Idx, varbinds = Vbs}.

now_ms() ->
    erlang:monotonic_time(millisecond).
