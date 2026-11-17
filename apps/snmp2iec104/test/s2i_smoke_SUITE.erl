-module(s2i_smoke_SUITE).
-moduledoc "Phase 0 smoke test: the release boots into the designed supervision tree.".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([root_supervisor_is_running/1,
         config_store_is_on_disc/1,
         root_is_rest_for_one/1,
         subtrees_start_in_design_order/1,
         dependencies_are_started/1]).

all() ->
    [root_supervisor_is_running,
     config_store_is_on_disc,
     root_is_rest_for_one,
     subtrees_start_in_design_order,
     dependencies_are_started].

init_per_suite(Config) ->
    %% nested and missing, like the release default "data/mnesia"
    ok = application:set_env(mnesia, dir, filename:join([?config(priv_dir, Config), "data", "mnesia"])),
    ok = application:load(s2i_core),
    ok = application:set_env(s2i_core, secret_key_file,
                             filename:join([?config(priv_dir, Config), "etc", "secret.key"])),
    ok = application:load(s2i_snmp),
    ok = application:set_env(s2i_snmp, dir, filename:join([?config(priv_dir, Config), "data", "snmp"])),
    ok = application:set_env(s2i_snmp, ip, "127.0.0.1"),
    {ok, Sock} = gen_udp:open(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Sock),
    ok = gen_udp:close(Sock),
    ok = application:set_env(s2i_snmp, port, Port),
    {ok, Started} = application:ensure_all_started(snmp2iec104),
    [{started, Started} | Config].

end_per_suite(Config) ->
    [application:stop(App) || App <- lists:reverse(?config(started, Config))],
    ok.

root_supervisor_is_running(_Config) ->
    ?assert(is_pid(whereis(s2i_sup))).

root_is_rest_for_one(_Config) ->
    %% Killing a child restarts it and every later sibling, never earlier ones.
    Before = pids(),
    restart_child(s2i_snmp_sup),
    After = pids(),
    ?assertEqual(maps:get(s2i_config, Before), maps:get(s2i_config, After)),
    ?assertEqual(maps:get(s2i_iec_sup, Before), maps:get(s2i_iec_sup, After)),
    ?assertNotEqual(maps:get(s2i_snmp_sup, Before), maps:get(s2i_snmp_sup, After)),
    ?assertNotEqual(maps:get(s2i_web_sup, Before), maps:get(s2i_web_sup, After)).

config_store_is_on_disc(_Config) ->
    ?assertEqual(disc_copies, mnesia:table_info(schema, storage_type)),
    ?assertEqual(disc_copies, mnesia:table_info(s2i_device, storage_type)).

subtrees_start_in_design_order(_Config) ->
    %% which_children/1 lists children in reverse start order
    Ids = lists:reverse([Id || {Id, Pid, _, _} <- supervisor:which_children(s2i_sup),
                               is_pid(Pid)]),
    ?assertEqual([s2i_config, s2i_iec_sup, s2i_snmp_sup, s2i_debug_sup, s2i_web_sup], Ids),
    [?assertEqual(Id, element(2, process_info(whereis(Id), registered_name))) || Id <- Ids].

dependencies_are_started(_Config) ->
    Running = [App || {App, _, _} <- application:which_applications()],
    [?assert(lists:member(App, Running), App)
     || App <- [s2i_core, s2i_snmp, s2i_iec, s2i_web, iec60870, ranch, cowboy, snmp, mnesia]].

%%% helpers

pids() ->
    maps:from_list([{Id, Pid} || {Id, Pid, _, _} <- supervisor:which_children(s2i_sup)]).

restart_child(Name) ->
    Pid = whereis(Name),
    Ref = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, process, Pid, _} -> ok after 1000 -> ct:fail(no_down) end,
    wait_registered(Name, Pid, 50).

wait_registered(Name, _OldPid, 0) ->
    ct:fail({not_restarted, Name});
wait_registered(Name, OldPid, N) ->
    case whereis(Name) of
        Pid when is_pid(Pid), Pid =/= OldPid -> ok;
        _ -> timer:sleep(20), wait_registered(Name, OldPid, N - 1)
    end.
