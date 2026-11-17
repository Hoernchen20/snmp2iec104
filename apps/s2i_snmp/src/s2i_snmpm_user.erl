-module(s2i_snmpm_user).
-moduledoc """
snmpm user callbacks. Every device registers its own snmpm user with its pid
as user data, so everything about its requests goes straight to it:

- `{snmp_pdu, ReqId, {ErrorStatus, ErrorIndex, Varbinds}}`
- `{snmp_error, ReqId, Reason}`
- `{snmp_report, Info}`: e.g. a v3 time-window report; it carries no request
  id, the device resends its outstanding requests
- `{snmp_trap, Info}` / `{snmp_inform, Info}`, or `{snmp_trap_from, Addr,
  Info}` for both when the source address is not the registered one

The default user (data `default`) gets what cannot be attributed to a
registered agent. Traps and informs from an unregistered address (typically
another source port than the polled one) reach `handle_agent/5` and are
passed to the device registered for the source IP (`s2i_trap_sources`); if
several devices share that IP, the trap is dropped as ambiguous.

Informs are acknowledged by snmpm itself before the callback runs.
""".
-behaviour(snmpm_user).

-export([handle_error/3, handle_agent/5, handle_pdu/4, handle_trap/3,
         handle_inform/3, handle_report/3]).

handle_pdu(_Target, ReqId, Resp, Pid) when is_pid(Pid) ->
    Pid ! {snmp_pdu, ReqId, Resp},
    ignore;
handle_pdu(Target, ReqId, _Resp, default) ->
    logger:debug("SNMP response ~p from ~p without a device", [ReqId, Target]),
    ignore.

handle_error(ReqId, Reason, Pid) when is_pid(Pid) ->
    Pid ! {snmp_error, ReqId, Reason},
    ignore;
handle_error(ReqId, Reason, default) ->
    logger:debug("SNMP error ~p: ~p", [ReqId, Reason]),
    ignore.

handle_report(_Target, Info, Pid) when is_pid(Pid) ->
    Pid ! {snmp_report, Info},
    ignore;
handle_report(Target, Info, default) ->
    logger:debug("SNMP report from ~p: ~p", [Target, Info]),
    ignore.

handle_trap(_Target, Info, Pid) when is_pid(Pid) ->
    Pid ! {snmp_trap, Info},
    ignore;
handle_trap(Target, _Info, default) ->
    logger:debug("SNMP trap from ~p without a device", [Target]),
    ignore.

handle_inform(_Target, Info, Pid) when is_pid(Pid) ->
    Pid ! {snmp_inform, Info},
    ignore;
handle_inform(Target, _Info, default) ->
    logger:debug("SNMP inform from ~p without a device", [Target]),
    ignore.

handle_agent(_Domain, {Ip, _Port} = Addr, Type, Info, _Data) when Type =:= trap; Type =:= inform ->
    case s2i_trap_sources:lookup(Ip) of
        [Pid] ->
            Pid ! {snmp_trap_from, Addr, Info},
            ignore;
        [] ->
            logger:debug("SNMP ~p from unknown agent ~ts", [Type, format(Addr)]),
            debug_unknown(Addr, Info),
            ignore;
        [_ | _] ->
            logger:warning("SNMP ~p from ~ts dropped: several devices use this IP address",
                           [Type, format(Addr)]),
            ignore
    end;
handle_agent(Domain, Addr, Type, _Info, _Data) ->
    logger:debug("SNMP ~p from unregistered agent ~p ~p", [Type, Domain, Addr]),
    ignore.

%% Unattributed traps still show up in the debug trap log.
debug_unknown({Ip, Port}, Info) ->
    try s2i_trap_match:normalize(Info) of
        Trap ->
            ok = s2i_debug:publish(<<"traps">>, Trap#{device => null, matched => [], misses => [],
                                                      from => iolist_to_binary(format({Ip, Port}))})
    catch
        _:_ -> ok
    end.

format({Ip, Port}) ->
    io_lib:format("~ts:~b", [inet:ntoa(Ip), Port]).
