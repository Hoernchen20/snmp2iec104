-module(s2i_snmpm_spike_SUITE).
-moduledoc """
Phase 4a spike: the `snmpm` behaviours the gateway is built on, checked
against a real `snmpa` agent (docs/DESIGN.md §8). If an OTP upgrade changes
one of them, this suite says which.

The suite module is also the snmpm user: every callback is forwarded to the
test process.
""".
-behaviour(snmpm_user).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, suite/0, init_per_testcase/2, end_per_testcase/2]).
-export([manager_runs_under_our_supervisor/1,
         async_response_goes_to_user_of_request/1,
         engine_id_is_mandatory_for_every_agent/1,
         trap_from_unregistered_address_goes_to_default_user/1,
         update_agent_info_keeps_old_address_for_traps/1,
         v3_first_request_gets_not_in_time_window_report/1,
         v3_trap_needs_user_under_agent_engine_id/1,
         v3_inform_needs_user_under_manager_engine_id/1,
         v3_unknown_engine_id_fails_fast/1]).
-export([handle_error/3, handle_agent/5, handle_pdu/4, handle_trap/3,
         handle_inform/3, handle_report/3]).

-define(SYS_NAME, [1, 3, 6, 1, 2, 1, 1, 5, 0]).
-define(MGR_ENGINE, "mgrEngine").
-define(USER, #{name => "s2i", auth => sha, auth_password => "authpass1",
                priv => aes, priv_password => "privpass1"}).

suite() -> [{timetrap, {seconds, 60}}].

all() ->
    [manager_runs_under_our_supervisor, async_response_goes_to_user_of_request,
     engine_id_is_mandatory_for_every_agent,
     trap_from_unregistered_address_goes_to_default_user,
     update_agent_info_keeps_old_address_for_traps,
     v3_first_request_gets_not_in_time_window_report,
     v3_trap_needs_user_under_agent_engine_id,
     v3_inform_needs_user_under_manager_engine_id,
     v3_unknown_engine_id_fails_fast].

init_per_testcase(TC, Config) ->
    Dir = filename:join(?config(priv_dir, Config), atom_to_list(TC)),
    AgentPort = free_udp_port(),
    MgrPort = free_udp_port(),
    ok = s2i_test_agent:start(filename:join(Dir, "agent"),
                              #{port => AgentPort, manager => {{127, 0, 0, 1}, MgrPort},
                                manager_engine_id => ?MGR_ENGINE, users => [?USER]}),
    flush(),
    MgrDir = filename:join(Dir, "manager") ++ "/",
    ok = filelib:ensure_path(MgrDir),
    ok = snmpm_conf:write_manager_config(MgrDir, "", [
        snmpm_conf:manager_entry(transports, [{transportDomainUdpIpv4, {{127, 0, 0, 1}, MgrPort}}]),
        snmpm_conf:manager_entry(engine_id, ?MGR_ENGINE),
        snmpm_conf:manager_entry(max_message_size, 1500)]),
    {ok, Sup} = snmpm_supervisor:start_link(normal, [{config, [{dir, MgrDir}, {db_dir, MgrDir}]},
                                                     {versions, [v1, v2, v3]},
                                                     {def_user_mod, ?MODULE},
                                                     {def_user_data, {default, self()}}]),
    unlink(Sup),
    ok = snmpm:register_user(spike, ?MODULE, self()),
    [{agent_port, AgentPort}, {manager, Sup} | Config].

end_per_testcase(_TC, Config) ->
    Sup = ?config(manager, Config),
    Ref = monitor(process, Sup),
    exit(Sup, shutdown),
    receive {'DOWN', Ref, _, _, _} -> ok end,
    s2i_test_agent:stop().

%%% ---------------------------------------------------------------------------
%%% snmpm_user: forward everything to the test process
%%% ---------------------------------------------------------------------------

handle_error(ReqId, Reason, Pid) -> to(Pid) ! {error, ReqId, Reason}, ignore.
handle_agent(Domain, Addr, Type, Info, Pid) -> to(Pid) ! {agent, Domain, Addr, Type, Info}, ignore.
handle_pdu(Target, ReqId, Resp, Pid) -> to(Pid) ! {pdu, Target, ReqId, Resp}, ignore.
handle_trap(Target, Info, Pid) -> to(Pid) ! {trap, Target, Info}, ignore.
handle_inform(Target, Info, Pid) -> to(Pid) ! {inform, Target, Info}, ignore.
handle_report(Target, Info, Pid) -> to(Pid) ! {report, Target, Info}, ignore.

to({default, Pid}) -> Pid;
to(Pid) -> Pid.

%%% ---------------------------------------------------------------------------
%%% tests
%%% ---------------------------------------------------------------------------

%% snmpm:start_link/1 returns `ok`, not `{ok, Pid}`; the gateway supervises
%% snmpm_supervisor:start_link(normal, Opts) itself (done in init_per_testcase).
manager_runs_under_our_supervisor(Config) ->
    Sup = ?config(manager, Config),
    ?assertEqual(Sup, whereis(snmpm_supervisor)),
    register_v2c(Config, "dev"),
    ?assertMatch({ok, {noError, 0, [{varbind, ?SYS_NAME, 'OCTET STRING', "agent", 1}]}, _},
                 snmpm:sync_get2(spike, "dev", [?SYS_NAME])).

async_response_goes_to_user_of_request(Config) ->
    register_v2c(Config, "dev"),
    {ok, ReqId} = snmpm:async_get2(spike, "dev", [?SYS_NAME, [1, 3, 6, 1, 2, 1, 1, 99, 0]]),
    receive
        {pdu, "dev", ReqId, {noError, 0, Vbs}} ->
            ?assertMatch([{varbind, ?SYS_NAME, 'OCTET STRING', "agent", 1},
                          {varbind, _, 'NULL', noSuchObject, 2}], Vbs)
    after 5000 -> ct:fail(no_response)
    end,
    %% an unanswered async request is NOT reported: snmpm only drops it
    %% (garbage collection) after its expiry. The gateway runs its own
    %% request timers and retries.
    ok = snmpm:register_agent(spike, "dead", agent_v2c(free_udp_port())),
    {ok, _} = snmpm:async_get2(spike, "dead", [?SYS_NAME], [{timeout, 300}]),
    receive Msg -> ct:fail({unexpected, Msg}) after 2000 -> ok end.

engine_id_is_mandatory_for_every_agent(Config) ->
    Port = ?config(agent_port, Config),
    ?assertEqual({error, {missing_mandatory_config, engine_id}},
                 snmpm:register_agent(spike, "dev", proplists:delete(engine_id, agent_v2c(Port)))).

%% Agents often send traps from another source port than the one they are
%% polled on: such traps are not matched to the agent but reach the default
%% user's handle_agent/5 with the source address; the gateway routes by IP.
trap_from_unregistered_address_goes_to_default_user(Config) ->
    register_v2c(Config, "dev"),
    s2i_test_agent:notify(trap, v2c),
    receive {trap, "dev", {noError, 0, _}} -> ok after 5000 -> ct:fail(no_trap) end,
    ok = snmpm:unregister_agent(spike, "dev"),
    ok = snmpm:register_agent(spike, "dev", agent_v2c(161)),
    AgentPort = ?config(agent_port, Config),
    s2i_test_agent:notify(trap, v2c),
    receive
        {agent, transportDomainUdpIpv4, {{127, 0, 0, 1}, AgentPort}, trap, {noError, 0, Vbs}} ->
            ?assertMatch([{varbind, [1, 3, 6, 1, 2, 1, 1, 3, 0], 'TimeTicks', _, 1},
                          {varbind, [1, 3, 6, 1, 6, 3, 1, 1, 4, 1, 0], 'OBJECT IDENTIFIER',
                           [1, 3, 6, 1, 6, 3, 1, 1, 5, 1], 2}], Vbs)
    after 5000 -> ct:fail(no_default_user_trap)
    end.

%% update_agent_info/4 on taddress does not update snmpm's address index:
%% traps from the old address still match the agent. The gateway changes an
%% address by unregister + register (i.e. restarting the device).
update_agent_info_keeps_old_address_for_traps(Config) ->
    register_v2c(Config, "dev"),
    ok = snmpm:update_agent_info(spike, "dev", taddress, {{127, 0, 0, 1}, 161}),
    s2i_test_agent:notify(trap, v2c),
    receive {trap, "dev", _} -> ok after 5000 -> ct:fail(no_trap) end.

%% snmpm does not resend after a usmStatsNotInTimeWindows report: the first
%% request to an agent (and the first after its reboot) gets no answer, the
%% report reaches handle_report/3 (without the request id), and the next
%% request succeeds because snmpm learnt boots/time from the (authenticated)
%% report. The gateway resends its outstanding requests on a report.
v3_first_request_gets_not_in_time_window_report(Config) ->
    register_v3(Config, "dev3"),
    {ok, ReqId} = snmpm:async_get2(spike, "dev3", [?SYS_NAME]),
    receive
        {report, "dev3", {noError, 0, [{varbind, [1, 3, 6, 1, 6, 3, 15, 1, 1, 2, 0], 'Counter32', _, 1}]}} ->
            ok
    after 5000 -> ct:fail(no_report)
    end,
    receive {error, ReqId, _} = Err -> ct:fail({unexpected, Err}) after 2000 -> ok end,
    ?assertMatch({ok, {noError, 0, [{varbind, ?SYS_NAME, 'OCTET STRING', "agent", 1}]}, _},
                 snmpm:sync_get2(spike, "dev3", [?SYS_NAME])).

v3_trap_needs_user_under_agent_engine_id(Config) ->
    register_v3(Config, "dev3"),
    s2i_test_agent:notify(trap, v3),
    receive {trap, "dev3", {noError, 0, _}} -> ok after 5000 -> ct:fail(no_trap) end,
    ok = snmpm:unregister_usm_user(s2i_test_agent:engine_id(), "s2i"),
    flush(),
    s2i_test_agent:notify(trap, v3),
    receive
        {error, _, {failed_processing_message, {securityError, usmStatsUnknownEngineIDs}}} -> ok
    after 5000 -> ct:fail(no_error)
    end.

%% For informs the manager is authoritative: the user must exist under the
%% manager's engine id. The agent's first inform runs into a time-window
%% report and its retransmission is accepted (duplicates are possible).
v3_inform_needs_user_under_manager_engine_id(Config) ->
    register_v3(Config, "dev3"),
    s2i_test_agent:notify(inform, v3),
    receive
        {error, _, {failed_processing_message, {securityError, usmStatsUnknownEngineIDs}}} -> ok
    after 5000 -> ct:fail(no_error)
    end,
    ok = snmpm:register_usm_user(?MGR_ENGINE, "s2i", usm(?MGR_ENGINE)),
    s2i_test_agent:notify(inform, v3),
    receive {inform, "dev3", {noError, 0, _}} -> ok after 10000 -> ct:fail(no_inform) end,
    receive {snmp_notification, inform, {got_response, _}} -> ok after 10000 -> ct:fail(no_ack) end.

v3_unknown_engine_id_fails_fast(Config) ->
    Port = ?config(agent_port, Config),
    ok = snmpm:register_agent(spike, "dev3", agent_v3(Port, "wrongEngine")),
    ?assertMatch({error, {send_failed, _, unknownSecurityName}},
                 snmpm:sync_get2(spike, "dev3", [?SYS_NAME])).

%%% ---------------------------------------------------------------------------
%%% helpers
%%% ---------------------------------------------------------------------------

register_v2c(Config, Target) ->
    ok = snmpm:register_agent(spike, Target, agent_v2c(?config(agent_port, Config))).

agent_v2c(Port) ->
    [{taddress, {{127, 0, 0, 1}, Port}}, {version, v2}, {sec_model, v2c},
     {community, "public"}, {engine_id, "unused"}].

register_v3(Config, Target) ->
    Engine = s2i_test_agent:engine_id(),
    ok = snmpm:register_usm_user(Engine, "s2i", usm(Engine)),
    ok = snmpm:register_agent(spike, Target, agent_v3(?config(agent_port, Config), Engine)).

agent_v3(Port, Engine) ->
    [{taddress, {{127, 0, 0, 1}, Port}}, {version, v3}, {sec_model, usm},
     {sec_name, "s2i"}, {sec_level, authPriv}, {engine_id, Engine}].

usm(Engine) ->
    [{sec_name, "s2i"},
     {auth, usmHMACSHAAuthProtocol}, {auth_key, s2i_test_agent:auth_key(sha, "authpass1", Engine)},
     {priv, usmAesCfb128Protocol}, {priv_key, s2i_test_agent:priv_key(sha, "privpass1", Engine)}].

free_udp_port() ->
    {ok, S} = gen_udp:open(0, [{ip, {127, 0, 0, 1}}]),
    {ok, P} = inet:port(S),
    ok = gen_udp:close(S),
    P.

flush() ->
    receive _ -> flush() after 200 -> ok end.
