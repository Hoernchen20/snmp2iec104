-module(s2i_snmp_SUITE).
-moduledoc """
SNMP polling end to end: activation → device processes → snmpm → agent →
transforms → live values of the IEC points (phase 4).

v1/v2c run against `s2i_fake_agent` (the test scripts values, tables,
silence and reboots); v3 runs against OTP's `snmpa` (`s2i_test_agent`).
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, suite/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([v2c_poll_publishes_values/1,
         v1_missing_oid_does_not_spoil_the_others/1,
         changes_are_published/1,
         device_down_and_recovery/1,
         instance_resolution_follows_renumbering/1,
         lost_instance_becomes_invalid/1,
         ambiguous_instance_is_not_resolved/1,
         chunks_respect_max_varbinds/1,
         removed_device_stops_polling/1,
         changed_device_restarts/1,
         disabled_device_is_not_polled/1,
         v3_auth_priv_with_configured_engine_id/1,
         v3_engine_id_discovery/1,
         v3_auth_protocols/1,
         v3_wrong_password_never_gets_valid/1]).

-define(ADMIN, <<"test">>).
-define(SERVER, <<"scada1">>).
-define(ENT, [1, 3, 6, 1, 4, 1, 99999]).
-define(TEMP, ?ENT ++ [1, 0]).
-define(STATUS, ?ENT ++ [2, 0]).
-define(IF_NAME(I), [1, 3, 6, 1, 2, 1, 31, 1, 1, 1, 1, I]).
-define(IF_OPER(I), [1, 3, 6, 1, 2, 1, 2, 2, 1, 8, I]).
%% IOAs: base 100, stride 10, instance slot 1
-define(IOA_TEMP, 100).
-define(IOA_STATUS, 101).
-define(IOA_IF1, 112).
-define(IOA_COMM, 50).
-define(IOA_SERVICES, 120).

suite() -> [{timetrap, {seconds, 90}}].

all() ->
    [v2c_poll_publishes_values, v1_missing_oid_does_not_spoil_the_others,
     changes_are_published, device_down_and_recovery,
     instance_resolution_follows_renumbering, lost_instance_becomes_invalid,
     ambiguous_instance_is_not_resolved, chunks_respect_max_varbinds,
     removed_device_stops_polling, changed_device_restarts, disabled_device_is_not_polled,
     {group, v3}].

groups() ->
    [{v3, [], [v3_auth_priv_with_configured_engine_id, v3_engine_id_discovery,
               v3_auth_protocols, v3_wrong_password_never_gets_valid]}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(iec60870),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(TC, Config) ->
    Dir = filename:join(?config(priv_dir, Config), atom_to_list(TC)),
    ok = filelib:ensure_path(Dir),
    ok = application:set_env(mnesia, dir, Dir),
    ok = application:set_env(s2i_core, secret_key_file, filename:join(Dir, "secret.key")),
    ok = application:set_env(s2i_snmp, dir, filename:join(Dir, "snmp")),
    ok = application:set_env(s2i_snmp, ip, "127.0.0.1"),
    MgrPort = free_udp_port(),
    ok = application:set_env(s2i_snmp, port, MgrPort),
    {ok, C} = s2i_config:start_link(),
    unlink(C),
    {ok, I} = s2i_iec_sup:start_link(),
    unlink(I),
    Agent = case is_v3(TC) of
                true ->
                    AgentPort = free_udp_port(),
                    ok = s2i_test_agent:start(filename:join(Dir, "agent"),
                                              #{port => AgentPort, manager => {{127, 0, 0, 1}, MgrPort},
                                                users => v3_users()}),
                    {snmpa, AgentPort};
                false ->
                    {ok, A} = s2i_fake_agent:start(),
                    fill_mib(A),
                    {fake, A}
            end,
    {ok, S} = s2i_snmp_sup:start_link(),
    unlink(S),
    [{agent, Agent}, {iec_port, free_tcp_port()} | Config].

end_per_testcase(_TC, Config) ->
    ok = stop(s2i_snmp_sup),
    ok = stop(s2i_iec_sup),
    ok = stop(s2i_config),
    stopped = mnesia:stop(),
    case ?config(agent, Config) of
        {fake, A} -> s2i_fake_agent:stop(A);
        {snmpa, _} -> s2i_test_agent:stop()
    end.

is_v3(TC) -> lists:prefix("v3_", atom_to_list(TC)).

stop(Name) ->
    Ref = monitor(process, whereis(Name)),
    exit(whereis(Name), shutdown),
    receive {'DOWN', Ref, _, _, _} -> ok end.

%%% ---------------------------------------------------------------------------
%%% fixtures
%%% ---------------------------------------------------------------------------

fill_mib(A) ->
    ok = s2i_fake_agent:set(A, ?TEMP, {'INTEGER', 215}),
    ok = s2i_fake_agent:set(A, ?STATUS, {'INTEGER', 1}),
    ok = s2i_fake_agent:set(A, ?IF_NAME(5), {'OCTET STRING', "ge-0/0/1"}),
    ok = s2i_fake_agent:set(A, ?IF_NAME(6), {'OCTET STRING', "ge-0/0/2"}),
    ok = s2i_fake_agent:set(A, ?IF_OPER(5), {'INTEGER', 1}),
    ok = s2i_fake_agent:set(A, ?IF_OPER(6), {'INTEGER', 2}).

server(Port) ->
    #{name => ?SERVER, transport => #{kind => tcp, ip => <<"127.0.0.1">>, port => Port},
      common_addresses => [1]}.

profile() ->
    #{name => <<"sw">>, ioa_stride => 10, poll_groups => #{<<"fast">> => 1000},
      resolvers => #{<<"if_name">> => #{column => <<"1.3.6.1.2.1.31.1.1.1.1">>}},
      datapoints =>
          [#{name => <<"temperature">>, oid => <<"1.3.6.1.4.1.99999.1.0">>, poll_group => <<"fast">>,
             mappings => [#{ioa_offset => 0, type => m_me_tf_1,
                            transform => #{kind => linear, scale => 0.1}}]},
           #{name => <<"status">>, oid => <<"1.3.6.1.4.1.99999.2.0">>, poll_group => <<"fast">>,
             mappings => [#{ioa_offset => 1, type => m_sp_tb_1,
                            transform => #{kind => enum, map => #{<<"1">> => true, <<"2">> => false}}}]},
           #{name => <<"if{slot}/oper">>, oid => <<"1.3.6.1.2.1.2.2.1.8.{index}">>, scope => instance,
             poll_group => <<"fast">>,
             mappings => [#{ioa_offset => 2, type => m_sp_tb_1,
                            transform => #{kind => enum, map => #{<<"1">> => true, <<"2">> => false}}}]}]}.

device(Port, Extra) ->
    maps:merge(#{name => <<"sw-a">>, host => <<"127.0.0.1">>, port => Port,
                 snmp => #{version => v2c, community => <<"public">>},
                 timeout => 300, retries => 1, down_after => 2,
                 profile => <<"sw">>, ioa_base => 100,
                 instances => [#{slot => 1, key => #{resolver => <<"if_name">>, value => <<"ge-0/0/1">>}}],
                 targets => #{<<"default">> => [#{server => ?SERVER, coa => 1}]},
                 comm_status => #{server => ?SERVER, coa => 1, ioa => ?IOA_COMM}},
               Extra).

fake_port(Config) ->
    {fake, A} = ?config(agent, Config),
    s2i_fake_agent:port(A).

agent(Config) ->
    {fake, A} = ?config(agent, Config),
    A.

start_fake(Config, DeviceExtra) ->
    activate([{server, server(?config(iec_port, Config))}, {profile, profile()},
              {device, device(fake_port(Config), DeviceExtra)}]).

activate(Entities) ->
    [{ok, _} = s2i_config:put(K, E, ?ADMIN) || {K, E} <- Entities],
    {ok, _} = s2i_config:activate(?ADMIN, <<>>),
    ok = s2i_snmp_mgr:sync().

live(Ioa) ->
    {ok, #{value := V, quality := Q}} = s2i_live:get(?SERVER, {1, Ioa}),
    {V, Q}.

valid(Ioa) ->
    case live(Ioa) of
        {V, []} -> {ok, V};
        _ -> invalid
    end.

%% Polls `Fun` until it returns true (10 s).
wait(Fun) -> wait(Fun, 100).

wait(Fun, 0) -> ct:fail({condition_not_met, erlang:fun_info(Fun, name)});
wait(Fun, N) ->
    case Fun() of
        true -> ok;
        _ -> timer:sleep(100), wait(Fun, N - 1)
    end.

wait_valid(Ioa, Value) ->
    wait(fun() -> valid(Ioa) =:= {ok, Value} end).

free_udp_port() ->
    {ok, S} = gen_udp:open(0, [{ip, {127, 0, 0, 1}}]),
    {ok, P} = inet:port(S),
    ok = gen_udp:close(S),
    P.

free_tcp_port() ->
    {ok, L} = gen_tcp:listen(0, []),
    {ok, P} = inet:port(L),
    ok = gen_tcp:close(L),
    P.

health(Name) ->
    case s2i_device:status(Name) of
        {ok, #{health := H}} -> H;
        {error, not_running} -> not_running
    end.

device_pid(Name) ->
    case [P || {Id, P, _, _} <- supervisor:which_children(s2i_devices_sup), Id =:= Name] of
        [P] when is_pid(P) -> P;
        [] -> undefined
    end.

%%% ---------------------------------------------------------------------------
%%% v1 / v2c
%%% ---------------------------------------------------------------------------

v2c_poll_publishes_values(Config) ->
    start_fake(Config, #{}),

    wait_valid(?IOA_TEMP, 21.5),
    wait_valid(?IOA_STATUS, true),
    wait_valid(?IOA_IF1, true),                % ge-0/0/1 resolved to ifIndex 5
    wait_valid(?IOA_COMM, true),
    {ok, #{health := up, resolved := #{<<"if_name">> := #{<<"ge-0/0/1">> := 5}}}} =
        s2i_device:status(<<"sw-a">>),
    %% time-tagged types carry the time of the response
    {ok, #{ts := Ts}} = s2i_live:get(?SERVER, {1, ?IOA_TEMP}),
    ?assert(abs(os:system_time(millisecond) - Ts) < 5000).

v1_missing_oid_does_not_spoil_the_others(Config) ->
    ok = s2i_fake_agent:delete(agent(Config), ?STATUS),
    start_fake(Config, #{snmp => #{version => v1, community => <<"public">>}}),
    wait_valid(?IOA_TEMP, 21.5),
    wait_valid(?IOA_IF1, true),
    {_, [invalid]} = live(?IOA_STATUS),
    %% the PDU failing with noSuchName is repeated without the missing OID
    Gets = s2i_fake_agent:gets(agent(Config)),
    ?assert(lists:any(fun(Oids) -> lists:member(?STATUS, Oids) end, Gets)),
    ?assert(lists:any(fun(Oids) -> lists:member(?TEMP, Oids) andalso not lists:member(?STATUS, Oids) end,
                      Gets)).

changes_are_published(Config) ->
    start_fake(Config, #{}),
    wait_valid(?IOA_TEMP, 21.5),
    ok = s2i_fake_agent:set(agent(Config), ?TEMP, {'INTEGER', 300}),
    ok = s2i_fake_agent:set(agent(Config), ?STATUS, {'INTEGER', 2}),
    wait_valid(?IOA_TEMP, 30.0),
    wait_valid(?IOA_STATUS, false),
    %% a value the transform cannot map: invalid, last value kept
    ok = s2i_fake_agent:set(agent(Config), ?STATUS, {'INTEGER', 9}),
    wait(fun() -> live(?IOA_STATUS) =:= {false, [invalid]} end).

device_down_and_recovery(Config) ->
    start_fake(Config, #{}),
    wait_valid(?IOA_TEMP, 21.5),
    wait_valid(?IOA_IF1, true),
    wait_valid(?IOA_COMM, true),
    ok = s2i_fake_agent:silent(agent(Config), true),
    %% down_after 2: points invalid with their last value, comm status false
    wait(fun() -> live(?IOA_TEMP) =:= {21.5, [invalid]} end),
    {true, [invalid]} = live(?IOA_IF1),
    wait_valid(?IOA_COMM, false),
    {ok, #{health := down}} = s2i_device:status(<<"sw-a">>),
    ok = s2i_fake_agent:silent(agent(Config), false),
    wait_valid(?IOA_COMM, true),
    %% unchanged values are sent again
    wait_valid(?IOA_TEMP, 21.5),
    wait_valid(?IOA_IF1, true),
    {ok, #{health := up}} = s2i_device:status(<<"sw-a">>).

instance_resolution_follows_renumbering(Config) ->
    A = agent(Config),
    start_fake(Config, #{}),
    wait_valid(?IOA_IF1, true),
    %% the agent renumbers its interfaces and reboots: ge-0/0/1 is now
    %% ifIndex 7 and down; index 5 belongs to another port
    ok = s2i_fake_agent:set(A, ?IF_NAME(7), {'OCTET STRING', "ge-0/0/1"}),
    ok = s2i_fake_agent:set(A, ?IF_OPER(7), {'INTEGER', 2}),
    ok = s2i_fake_agent:set(A, ?IF_NAME(5), {'OCTET STRING', "ge-0/0/9"}),
    ok = s2i_fake_agent:reboot(A),
    wait_valid(?IOA_IF1, false),
    wait(fun() ->
                 {ok, #{resolved := #{<<"if_name">> := R}}} = s2i_device:status(<<"sw-a">>),
                 maps:get(<<"ge-0/0/1">>, R, undefined) =:= 7
         end).

lost_instance_becomes_invalid(Config) ->
    A = agent(Config),
    start_fake(Config, #{}),
    wait_valid(?IOA_IF1, true),
    ok = s2i_fake_agent:delete(A, ?IF_NAME(5)),
    ok = s2i_fake_agent:reboot(A),
    wait(fun() -> live(?IOA_IF1) =:= {true, [invalid]} end),
    {ok, #{unresolved := [<<"sw-a/if1/oper">>]}} = s2i_device:status(<<"sw-a">>),
    %% the other points are unaffected
    {ok, 21.5} = valid(?IOA_TEMP).

ambiguous_instance_is_not_resolved(Config) ->
    A = agent(Config),
    ok = s2i_fake_agent:set(A, ?IF_NAME(6), {'OCTET STRING', "ge-0/0/1"}),
    start_fake(Config, #{}),
    wait_valid(?IOA_TEMP, 21.5),
    {_, [invalid]} = live(?IOA_IF1),
    {ok, #{unresolved := [<<"sw-a/if1/oper">>]}} = s2i_device:status(<<"sw-a">>),
    %% never polled under a guessed index
    ?assertNot(lists:any(fun(Oids) -> lists:member(?IF_OPER(5), Oids) orelse
                                          lists:member(?IF_OPER(6), Oids) end,
                         s2i_fake_agent:gets(A))).

chunks_respect_max_varbinds(Config) ->
    start_fake(Config, #{max_varbinds => 2}),
    wait_valid(?IOA_IF1, true),
    Gets = s2i_fake_agent:gets(agent(Config)),
    %% sysUpTime + 3 datapoints in chunks of at most 2
    ?assert(lists:all(fun(Oids) -> length(Oids) =< 2 end, Gets)),
    ?assert(length(Gets) >= 2).

removed_device_stops_polling(Config) ->
    A = agent(Config),
    start_fake(Config, #{}),
    wait_valid(?IOA_TEMP, 21.5),
    ok = s2i_config:delete(device, <<"sw-a">>, ?ADMIN),
    {ok, _} = s2i_config:activate(?ADMIN, <<>>),
    ok = s2i_snmp_mgr:sync(),
    ?assertEqual(undefined, device_pid(<<"sw-a">>)),
    N = s2i_fake_agent:requests(A),
    timer:sleep(1500),
    ?assertEqual(N, s2i_fake_agent:requests(A)).

changed_device_restarts(Config) ->
    start_fake(Config, #{}),
    wait_valid(?IOA_TEMP, 21.5),
    Pid = device_pid(<<"sw-a">>),
    %% unrelated change (another server): the device keeps running
    activate([{server, (server(free_tcp_port()))#{name => <<"other">>}}]),
    ?assertEqual(Pid, device_pid(<<"sw-a">>)),
    %% change of the device itself: restart
    activate([{device, device(fake_port(Config), #{timeout => 400})}]),
    Pid2 = device_pid(<<"sw-a">>),
    ?assert(is_pid(Pid2) andalso Pid2 =/= Pid),
    ?assertNot(is_process_alive(Pid)).

disabled_device_is_not_polled(Config) ->
    start_fake(Config, #{enabled => false}),
    ?assertEqual(undefined, device_pid(<<"sw-a">>)),
    timer:sleep(1200),
    ?assertEqual(0, s2i_fake_agent:requests(agent(Config))),
    {_, [invalid]} = live(?IOA_TEMP).

%%% ---------------------------------------------------------------------------
%%% v3 (snmpa)
%%% ---------------------------------------------------------------------------

v3_users() ->
    [#{name => N, auth => A, auth_password => "authpass1", priv => P, priv_password => "privpass1"}
     || {N, A, P} <- [{"u_sha_aes", sha, aes}, {"u_md5_des", md5, des}, {"u_sha256_aes", sha256, aes},
                      {"u_sha512_des", sha512, des}]].

v3_profile() ->
    #{name => <<"agent">>, poll_groups => #{<<"fast">> => 1000},
      datapoints =>
          [#{name => <<"services">>, oid => <<"1.3.6.1.2.1.1.7.0">>, poll_group => <<"fast">>,
             mappings => [#{ioa_offset => 0, type => m_me_nb_1,
                            transform => #{kind => linear}}]}]}.

v3_device(Config, Name, Base, Snmp) ->
    {snmpa, Port} = ?config(agent, Config),
    #{name => Name, host => <<"127.0.0.1">>, port => Port, snmp => Snmp,
      timeout => 500, retries => 1, down_after => 3, profile => <<"agent">>, ioa_base => Base,
      targets => #{<<"default">> => [#{server => ?SERVER, coa => 1}]}}.

v3(User, Auth, Priv) ->
    #{version => v3, user => list_to_binary(User), sec_level => auth_priv,
      auth_protocol => Auth, auth_password => <<"authpass1">>,
      priv_protocol => Priv, priv_password => <<"privpass1">>}.

agent_engine_hex() ->
    binary:encode_hex(list_to_binary(s2i_test_agent:engine_id()), lowercase).

v3_auth_priv_with_configured_engine_id(Config) ->
    Snmp = (v3("u_sha_aes", sha, aes))#{engine_id => agent_engine_hex()},
    activate([{server, server(?config(iec_port, Config))}, {profile, v3_profile()},
              {device, v3_device(Config, <<"agent">>, ?IOA_SERVICES, Snmp)}]),
    %% sysServices.0 = 72; the first request runs into the time-window
    %% report and is resent at once, so no cycle fails
    wait_valid(?IOA_SERVICES, 72),
    {ok, #{health := up, failures := 0}} = s2i_device:status(<<"agent">>).

v3_engine_id_discovery(Config) ->
    {snmpa, Port} = ?config(agent, Config),
    ?assertEqual({ok, s2i_test_agent:engine_id()},
                 s2i_snmp_discover:engine_id({127, 0, 0, 1}, Port, 1000, 1)),
    activate([{server, server(?config(iec_port, Config))}, {profile, v3_profile()},
              {device, v3_device(Config, <<"agent">>, ?IOA_SERVICES, v3("u_sha_aes", sha, aes))}]),
    wait_valid(?IOA_SERVICES, 72).

v3_auth_protocols(Config) ->
    Devices = [{device, v3_device(Config, list_to_binary(U), ?IOA_SERVICES + I, v3(U, A, P))}
               || {I, {U, A, P}} <- lists:enumerate(0, [{"u_md5_des", md5, des},
                                                         {"u_sha256_aes", sha256, aes},
                                                         {"u_sha512_des", sha512, des}])],
    activate([{server, server(?config(iec_port, Config))}, {profile, v3_profile()} | Devices]),
    [wait_valid(?IOA_SERVICES + I, 72) || I <- [0, 1, 2]].

v3_wrong_password_never_gets_valid(Config) ->
    Snmp = (v3("u_sha_aes", sha, aes))#{auth_password => <<"wrongpass">>},
    activate([{server, server(?config(iec_port, Config))}, {profile, v3_profile()},
              {device, v3_device(Config, <<"agent">>, ?IOA_SERVICES, Snmp)}]),
    wait(fun() -> health(<<"agent">>) =:= down end),
    {_, [invalid]} = live(?IOA_SERVICES).
