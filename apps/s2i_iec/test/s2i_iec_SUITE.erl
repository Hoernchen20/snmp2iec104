-module(s2i_iec_SUITE).
-moduledoc """
IEC side end to end: activation → running erl60870 servers, invalid seeding,
publish, point add/remove without restart, server restart on server-level
change, crash recovery from the live-value table, background scan, command
rejection. A real IEC 104 client (s2i_iec104_client) talks to the servers.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("iec60870/include/iec60870_asdu.hrl").

-export([all/0, suite/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([points_start_invalid/1,
         publish_reaches_client/1,
         publish_to_unconfigured_point_is_dropped/1,
         publish_to_unknown_server_is_harmless/1,
         removing_device_removes_points_without_restart/1,
         adding_device_sends_invalid_points/1,
         server_change_restarts_server/1,
         removed_server_is_stopped/1,
         library_crash_keeps_values/1,
         manager_crash_keeps_values/1,
         background_scan/1,
         commands_are_rejected/1,
         redundancy_groups/1,
         no_active_config_no_servers/1]).

-define(C, s2i_iec104_client).
-define(ADMIN, <<"test">>).

suite() -> [{timetrap, {seconds, 60}}].

all() ->
    [points_start_invalid, publish_reaches_client, publish_to_unconfigured_point_is_dropped,
     publish_to_unknown_server_is_harmless,
     removing_device_removes_points_without_restart, adding_device_sends_invalid_points,
     server_change_restarts_server, removed_server_is_stopped, library_crash_keeps_values,
     manager_crash_keeps_values, background_scan, commands_are_rejected, redundancy_groups,
     no_active_config_no_servers].

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
    {ok, C} = s2i_config:start_link(),
    unlink(C),
    Port = free_port(),
    case TC of
        no_active_config_no_servers -> ok;
        _ -> activate(base_config(Port, #{}))
    end,
    {ok, I} = s2i_iec_sup:start_link(),
    unlink(I),
    [{port, Port} | Config].

end_per_testcase(_TC, _Config) ->
    ok = stop(s2i_iec_sup),
    ok = stop(s2i_config),
    stopped = mnesia:stop(),
    [] = [N || {{s2i, _} = N, _} <- iec60870:which_servers()],
    ok.

stop(Name) ->
    Ref = monitor(process, whereis(Name)),
    exit(whereis(Name), shutdown),
    receive {'DOWN', Ref, _, _, _} -> ok end.

%%% ---------------------------------------------------------------------------
%%% fixtures
%%% ---------------------------------------------------------------------------

free_port() ->
    {ok, L} = gen_tcp:listen(0, []),
    {ok, P} = inet:port(L),
    ok = gen_tcp:close(L),
    P.

server(Port, Extra) ->
    maps:merge(#{name => <<"scada1">>, transport => #{kind => tcp, ip => <<"127.0.0.1">>, port => Port},
                 common_addresses => [1]}, Extra).

profile() ->
    #{name => <<"sw">>, poll_groups => #{<<"status">> => 30000},
      datapoints => [#{name => <<"temperature">>, oid => <<"1.3.6.1.2.1.1.1.0">>,
                       mappings => [#{ioa_offset => 0, type => m_me_tf_1, transform => #{kind => linear}}]},
                     #{name => <<"status">>, oid => <<"1.3.6.1.2.1.1.2.0">>,
                       mappings => [#{ioa_offset => 1, type => m_sp_tb_1,
                                      transform => #{kind => enum, map => #{<<"1">> => true}}}]}]}.

device(Name, Base) ->
    #{name => Name, host => <<"10.0.0.1">>, snmp => #{version => v2c, community => <<"public">>},
      profile => <<"sw">>, ioa_base => Base,
      targets => #{<<"default">> => [#{server => <<"scada1">>, coa => 1}]}}.

base_config(Port, ServerExtra) ->
    [{server, server(Port, ServerExtra)},
     {profile, profile()},
     {device, (device(<<"sw-a">>, 100))#{comm_status => #{server => <<"scada1">>, coa => 1, ioa => 50}}},
     {device, device(<<"sw-b">>, 200)}].

activate(Entities) ->
    [{ok, _} = s2i_config:put(K, E, ?ADMIN) || {K, E} <- Entities],
    {ok, _} = s2i_config:activate(?ADMIN, <<>>),
    ok.

%% Activation is applied asynchronously by s2i_iec_mgr; this waits until it is done.
activate_and_sync(Entities) ->
    activate(Entities),
    ok = s2i_iec_mgr:sync().

delete_and_sync(Kind, Name) ->
    ok = s2i_config:delete(Kind, Name, ?ADMIN),
    {ok, _} = s2i_config:activate(?ADMIN, <<>>),
    ok = s2i_iec_mgr:sync().

connect(Config) ->
    ok = s2i_iec_mgr:sync(),
    ?C:connect(?config(port, Config)).

-define(INVALID_POINTS,
        [{50, false, [invalid]}, {100, 0.0, [invalid]}, {101, false, [invalid]},
         {200, 0.0, [invalid]}, {201, false, [invalid]}]).

%%% ---------------------------------------------------------------------------
%%% tests
%%% ---------------------------------------------------------------------------

points_start_invalid(Config) ->
    S = connect(Config),
    ?assertEqual(?INVALID_POINTS, ?C:gi(S, 1)).

publish_reaches_client(Config) ->
    S = connect(Config),
    ok = s2i_iec:publish(<<"scada1">>, [{{1, 101}, #{type => m_sp_tb_1, value => true}},
                                         {{1, 100}, #{type => m_me_tf_1, value => 41.5}}]),
    Objs = recv_objects(S, 2),
    ?assertEqual([{100, 41.5}, {101, true}], lists:sort([{I, V} || #object{ioa = I, value = V} <- Objs])),
    [{100, 41.5, []}, {101, true, []}] = [P || {I, _, _} = P <- ?C:gi(S, 1), I =:= 100 orelse I =:= 101].

publish_to_unconfigured_point_is_dropped(Config) ->
    S = connect(Config),
    ok = s2i_iec:publish(<<"scada1">>, [{{1, 999}, #{type => m_sp_tb_1, value => true}},
                                         {{7, 101}, #{type => m_sp_tb_1, value => true}}]),
    ok = ?C:expect_no_data(S, 300),
    ?assertEqual(?INVALID_POINTS, ?C:gi(S, 1)).

publish_to_unknown_server_is_harmless(_Config) ->
    ok = s2i_iec:publish(<<"nope">>, [{{1, 101}, #{type => m_sp_tb_1, value => true}}]).

removing_device_removes_points_without_restart(Config) ->
    S = connect(Config),
    ok = delete_and_sync(device, <<"sw-b">>),
    ok = ?C:expect_no_data(S, 300),
    %% same connection: the server was not restarted
    ?assertEqual([{50, false, [invalid]}, {100, 0.0, [invalid]}, {101, false, [invalid]}], ?C:gi(S, 1)).

adding_device_sends_invalid_points(Config) ->
    S = connect(Config),
    ok = activate_and_sync([{device, device(<<"sw-c">>, 300)}]),
    Objs = recv_objects(S, 2),
    ?assertEqual([{300, [invalid]}, {301, [invalid]}],
                 lists:sort([{I, Q} || #object{ioa = I, quality = Q} <- Objs])).

server_change_restarts_server(Config) ->
    Port = ?config(port, Config),
    S = connect(Config),
    ok = s2i_iec:publish(<<"scada1">>, [{{1, 101}, #{type => m_sp_tb_1, value => true}}]),
    [_] = recv_objects(S, 1),
    ok = activate_and_sync([{server, server(Port, #{params => #{k => 6, w => 4}})}]),
    ok = ?C:expect_closed(S, 2000),
    %% the published value survives the restart (if the port is not free yet,
    %% the manager retries the start)
    S2 = retry_connect(Port, 50),
    {101, true, []} = lists:keyfind(101, 1, ?C:gi(S2, 1)).

removed_server_is_stopped(Config) ->
    _ = connect(Config),
    [ok = s2i_config:delete(device, D, ?ADMIN) || D <- [<<"sw-a">>, <<"sw-b">>]],
    ok = delete_and_sync(server, <<"scada1">>),
    ?assertEqual({error, econnrefused}, ?C:try_connect(?config(port, Config))),
    ?assertEqual([], [N || {{s2i, _} = N, _} <- iec60870:which_servers()]).

library_crash_keeps_values(Config) ->
    S = connect(Config),
    ok = s2i_iec:publish(<<"scada1">>, [{{1, 101}, #{type => m_sp_tb_1, value => true}}]),
    [_] = recv_objects(S, 1),
    Ctl = iec60870_registry:whereis_name({ctl, {s2i, <<"scada1">>}}),
    exit(Ctl, kill),
    S2 = retry_connect(?config(port, Config), 50),
    {101, true, []} = lists:keyfind(101, 1, ?C:gi(S2, 1)),
    ?assertEqual({200, 0.0, [invalid]}, lists:keyfind(200, 1, ?C:gi(S2, 1))).

manager_crash_keeps_values(Config) ->
    S = connect(Config),
    ok = s2i_iec:publish(<<"scada1">>, [{{1, 101}, #{type => m_sp_tb_1, value => true}}]),
    [_] = recv_objects(S, 1),
    Mgr = whereis(s2i_iec_mgr),
    exit(Mgr, kill),
    ok = wait_new_pid(s2i_iec_mgr, Mgr, 50),
    S2 = retry_connect(?config(port, Config), 50),
    {101, true, []} = lists:keyfind(101, 1, ?C:gi(S2, 1)),
    %% still reconciling after the restart
    ok = delete_and_sync(device, <<"sw-b">>),
    false = lists:keyfind(200, 1, ?C:gi(S2, 1)).

background_scan(Config) ->
    Port = ?config(port, Config),
    ok = activate_and_sync([{server, server(Port, #{background_scan => 1000})}]),
    S = ?C:connect(Port),
    #asdu{cot = background} = ?C:recv_asdu(S, 3000).

commands_are_rejected(Config) ->
    S = connect(Config),
    ok = ?C:send_asdu(S, #asdu{type = c_sc_na_1, cot = act, coa = 1,
                               objects = [iec60870_asdu:single_command(101, true, #{})]}),
    #asdu{type = c_sc_na_1, negative = true} = ?C:recv_asdu(S).

redundancy_groups(Config) ->
    Port = ?config(port, Config),
    Red = #{mode => multiple, groups => [#{name => <<"local">>, match => [<<"127.0.0.0/8">>]}]},
    ok = activate_and_sync([{server, server(Port, #{redundancy => Red})}]),
    S = ?C:connect(Port),
    ok = s2i_iec:publish(<<"scada1">>, [{{1, 101}, #{type => m_sp_tb_1, value => true}}]),
    [#object{ioa = 101, value = true}] = recv_objects(S, 1).

no_active_config_no_servers(Config) ->
    ok = s2i_iec_mgr:sync(),
    ?assertEqual({error, econnrefused}, ?C:try_connect(?config(port, Config))),
    activate_and_sync(base_config(?config(port, Config), #{})),
    S = ?C:connect(?config(port, Config)),
    ?assertEqual(?INVALID_POINTS, ?C:gi(S, 1)).

%%% ---------------------------------------------------------------------------

recv_objects(_S, 0) -> [];
recv_objects(S, N) ->
    #asdu{cot = spontaneous, objects = Objs} = ?C:recv_asdu(S),
    Objs ++ recv_objects(S, N - length(Objs)).

%% After a crash the listener comes back a moment later; a connection made
%% while it restarts may be closed again, so retry the whole handshake.
retry_connect(Port, 0) ->
    ?C:connect(Port);
retry_connect(Port, N) ->
    try ?C:connect(Port)
    catch error:_ -> timer:sleep(100), retry_connect(Port, N - 1)
    end.

wait_new_pid(Name, Old, 0) -> error({not_restarted, Name, Old});
wait_new_pid(Name, Old, N) ->
    case whereis(Name) of
        Pid when is_pid(Pid), Pid =/= Old -> ok;
        _ -> timer:sleep(50), wait_new_pid(Name, Old, N - 1)
    end.
