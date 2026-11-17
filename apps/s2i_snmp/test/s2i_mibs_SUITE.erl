-module(s2i_mibs_SUITE).
-moduledoc """
s2i_mibs: upload, compile (with snmpc), dependency order, errors, cache,
and the name index of uploaded and built-in MIBs.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([builtin_mibs_are_indexed/1,
         upload_and_look_up/1,
         smiv1_traps/1,
         imports_in_any_order/1,
         bundle_in_one_file/1,
         compile_errors_are_reported/1,
         builtin_names_are_skipped/1,
         invalid_uploads_are_rejected/1,
         replace_and_delete/1,
         cache_survives_restart/1,
         changes_are_audited/1]).

-define(ADMIN, <<"admin">>).
-define(TEST_STATE, [1, 3, 6, 1, 4, 1, 99999, 1, 1]).

all() ->
    [builtin_mibs_are_indexed,
     upload_and_look_up,
     smiv1_traps,
     imports_in_any_order,
     bundle_in_one_file,
     compile_errors_are_reported,
     builtin_names_are_skipped,
     invalid_uploads_are_rejected,
     replace_and_delete,
     cache_survives_restart,
     changes_are_audited].

init_per_testcase(TC, Config) ->
    Dir = filename:join(?config(priv_dir, Config), atom_to_list(TC)),
    ok = filelib:ensure_path(Dir),
    ok = application:set_env(mnesia, dir, filename:join(Dir, "mnesia")),
    MibDir = filename:join(Dir, "mibs"),
    ok = application:set_env(s2i_snmp, mib_dir, MibDir),
    _ = application:load(snmp),
    ok = s2i_config_store:start(),
    {ok, _} = start(),
    [{mib_dir, MibDir} | Config].

end_per_testcase(_TC, _Config) ->
    ok = stop(),
    stopped = mnesia:stop(),
    ok = application:unset_env(s2i_snmp, mib_dir),
    ok.

start() ->
    {ok, Pid} = s2i_mibs:start_link(),
    unlink(Pid),
    _ = sys:get_state(s2i_mibs),           % initial compile done
    {ok, Pid}.

stop() ->
    gen_server:stop(s2i_mibs).

src(Config, Name) ->
    {ok, B} = file:read_file(filename:join(?config(data_dir, Config), Name ++ ".mib")),
    B.

upload(Config, Names) ->
    s2i_mibs:put([src(Config, N) || N <- Names], ?ADMIN).

status(Name) ->
    {ok, #{status := S}} = s2i_mibs:get(Name),
    S.

%%% cases

builtin_mibs_are_indexed(_Config) ->
    {ok, #{origin := builtin, status := ok, objects := N}} = s2i_mibs:get(<<"SNMPv2-MIB">>),
    ?assert(N > 10),
    ?assertEqual({error, not_found}, s2i_mibs:get(<<"OTP-REG">>)),
    ?assertMatch({ok, #{name := <<"sysDescr">>, kind := scalar}, [0]},
                 s2i_mibs:translate([1, 3, 6, 1, 2, 1, 1, 1, 0])),
    ?assertMatch({ok, #{name := <<"ifOperStatus">>, enums := [#{value := 1, name := <<"up">>} | _]}, [7]},
                 s2i_mibs:translate([1, 3, 6, 1, 2, 1, 2, 2, 1, 8, 7])),
    ?assertMatch({ok, #{name := <<"coldStart">>, kind := notification}, []},
                 s2i_mibs:translate([1, 3, 6, 1, 6, 3, 1, 1, 5, 1])),
    ?assertEqual({ok, [1, 3, 6, 1, 2, 1, 1, 5, 0]}, s2i_mibs:resolve(<<"sysName.0">>)),
    ?assertMatch([{[1, 3, 6, 1, 2, 1, 1], #{name := <<"system">>}, true} | _],
                 s2i_mibs:children([1, 3, 6, 1, 2, 1])),
    {ok, Src} = s2i_mibs:source(<<"SNMPv2-MIB">>),
    ?assertMatch({_, _}, binary:match(Src, <<"SNMPv2-MIB DEFINITIONS">>)),
    ?assertEqual({error, not_found}, s2i_mibs:source(<<"../../etc/passwd">>)).

upload_and_look_up(Config) ->
    {ok, #{modules := [Info], skipped := []}} = upload(Config, ["TEST-MIB"]),
    ?assertMatch(#{name := <<"TEST-MIB">>, origin := uploaded, status := ok, uploaded_by := ?ADMIN,
                   imports := [<<"SNMPv2-SMI">>, <<"SNMPv2-TC">>]}, Info),
    ?assert(maps:get(objects, Info) >= 9),
    {ok, State, [0]} = s2i_mibs:translate(?TEST_STATE ++ [0]),
    ?assertMatch(#{module := <<"TEST-MIB">>, name := <<"testState">>, kind := scalar,
                   description := <<"Breaker state">>, access := <<"read-only">>,
                   enums := [#{value := 1, name := <<"on">>}, #{value := 2, name := <<"off">>},
                             #{value := 3, name := <<"unknown">>}]}, State),
    %% textual conventions bring their enums and units
    ?assertMatch({ok, #{syntax := <<"TruthValue">>, enums := [#{name := <<"true">>}, #{name := <<"false">>}]}, [5]},
                 s2i_mibs:translate([1, 3, 6, 1, 4, 1, 99999, 1, 2, 1, 3, 5])),
    ?assertMatch({ok, #{units := <<"chars">>, syntax := <<"DisplayString">>}},
                 s2i_mibs:lookup([1, 3, 6, 1, 4, 1, 99999, 1, 2, 1, 2])),
    ?assertMatch({ok, #{kind := notification, objects := [_]}},
                 s2i_mibs:lookup([1, 3, 6, 1, 4, 1, 99999, 0, 1])),
    ?assertEqual({ok, ?TEST_STATE ++ [0]}, s2i_mibs:resolve(<<"TEST-MIB::testState.0">>)),
    ?assertMatch([#{name := <<"testTable">>}], s2i_mibs:search(<<"testtable">>, 5)),
    ?assertMatch([{[1, 3, 6, 1, 4, 1, 99999], #{name := <<"testMIB">>}, true}],
                 s2i_mibs:children([1, 3, 6, 1, 4, 1])),
    ?assertEqual({ok, src(Config, "TEST-MIB")}, s2i_mibs:source(<<"TEST-MIB">>)).

smiv1_traps(Config) ->
    {ok, #{modules := [#{status := ok}]}} = upload(Config, ["ACME-V1-MIB"]),
    ?assertMatch({ok, #{name := <<"acmeTrap">>, kind := notification, description := <<"Acme trap">>}},
                 s2i_mibs:lookup([1, 3, 6, 1, 4, 1, 4242, 0, 7])).

imports_in_any_order(Config) ->
    {ok, #{modules := [Ext]}} = upload(Config, ["TEST-EXT-MIB"]),
    ?assertMatch(#{status := missing_imports, missing := [<<"TEST-MIB">>], objects := 0}, Ext),
    ?assertEqual(error, s2i_mibs:lookup([1, 3, 6, 1, 4, 1, 99999, 1, 9, 1])),
    {ok, _} = upload(Config, ["TEST-MIB"]),
    ?assertEqual(ok, status(<<"TEST-EXT-MIB">>)),
    ?assertMatch({ok, #{name := <<"testTemperature">>, units := <<"0.1 degC">>}},
                 s2i_mibs:lookup([1, 3, 6, 1, 4, 1, 99999, 1, 9, 1])).

bundle_in_one_file(Config) ->
    Bundle = <<(src(Config, "TEST-EXT-MIB"))/binary, "\n", (src(Config, "TEST-MIB"))/binary>>,
    {ok, #{modules := Ms}} = s2i_mibs:put([Bundle], ?ADMIN),
    ?assertEqual([{<<"TEST-EXT-MIB">>, ok}, {<<"TEST-MIB">>, ok}], [{N, S} || #{name := N, status := S} <- Ms]).

compile_errors_are_reported(Config) ->
    Dependent = binary:replace(src(Config, "TEST-EXT-MIB"), <<"FROM TEST-MIB">>, <<"FROM BROKEN-MIB">>),
    Dependent1 = binary:replace(Dependent, <<"testObjects">>, <<"brokenMIB">>, [global]),
    {ok, #{modules := [Broken, Dep]}} = s2i_mibs:put([src(Config, "BROKEN-MIB"), Dependent1], ?ADMIN),
    ct:log("~p~n~p", [Broken, Dep]),
    #{status := error, messages := [#{message := Msg} | _]} = Broken,
    ?assertNotEqual(nomatch, binary:match(Msg, <<"NoSuchType">>)),
    ?assertMatch(#{status := dependency_failed, dependencies := [<<"BROKEN-MIB">>]}, Dep),
    %% the rest of the library is unaffected
    {ok, _} = upload(Config, ["TEST-MIB"]),
    ?assertEqual(error, status(<<"BROKEN-MIB">>)),
    ?assertEqual(ok, status(<<"TEST-MIB">>)).

builtin_names_are_skipped(Config) ->
    {ok, Src} = s2i_mibs:source(<<"SNMPv2-MIB">>),
    Smi = <<"SNMPv2-SMI DEFINITIONS ::= BEGIN END">>,
    {ok, #{modules := [#{name := <<"TEST-MIB">>}], skipped := [<<"SNMPv2-MIB">>, <<"SNMPv2-SMI">>]}} =
        s2i_mibs:put([Src, Smi, src(Config, "TEST-MIB")], ?ADMIN),
    ?assertEqual({error, builtin}, s2i_mibs:delete(<<"SNMPv2-MIB">>, ?ADMIN)),
    ?assertMatch({ok, #{origin := builtin}}, s2i_mibs:get(<<"SNMPv2-MIB">>)).

invalid_uploads_are_rejected(Config) ->
    ?assertMatch({error, [#{path := [sources, 1], error := no_module}]},
                 s2i_mibs:put([src(Config, "TEST-MIB"), <<"hello">>], ?ADMIN)),
    ?assertMatch({error, [#{path := [sources, 0], error := no_end, detail := #{module := <<"X-MIB">>}}]},
                 s2i_mibs:put([<<"X-MIB DEFINITIONS ::= BEGIN">>], ?ADMIN)),
    ?assertMatch({error, [#{path := [sources], error := duplicate_module}]},
                 upload(Config, ["TEST-MIB", "TEST-MIB"])),
    ?assertMatch({error, [#{path := [sources], error := required}]}, s2i_mibs:put([], ?ADMIN)),
    ?assertMatch({error, [#{path := [sources, 0], error := invalid_type}]}, s2i_mibs:put([42], ?ADMIN)),
    %% nothing was stored
    ?assertEqual({error, not_found}, s2i_mibs:get(<<"TEST-MIB">>)).

replace_and_delete(Config) ->
    {ok, _} = upload(Config, ["TEST-MIB", "TEST-EXT-MIB"]),
    New = binary:replace(src(Config, "TEST-MIB"), <<"testState">>, <<"breakerState">>, [global]),
    {ok, #{modules := [#{status := ok}]}} = s2i_mibs:put([New], ?ADMIN),
    ?assertMatch({ok, #{name := <<"breakerState">>}}, s2i_mibs:lookup(?TEST_STATE)),
    ?assertEqual({error, not_found}, s2i_mibs:resolve(<<"testState">>)),
    ok = s2i_mibs:delete(<<"TEST-MIB">>, ?ADMIN),
    ?assertEqual({error, not_found}, s2i_mibs:get(<<"TEST-MIB">>)),
    ?assertEqual({error, not_found}, s2i_mibs:delete(<<"TEST-MIB">>, ?ADMIN)),
    ?assertEqual(missing_imports, status(<<"TEST-EXT-MIB">>)),
    ?assertMatch({ok, #{name := <<"enterprises">>}, [99999, 1, 1]}, s2i_mibs:translate(?TEST_STATE)),
    ?assertEqual([], filelib:wildcard(filename:join(?config(mib_dir, Config), "TEST-MIB.*"))).

cache_survives_restart(Config) ->
    MibDir = ?config(mib_dir, Config),
    {ok, _} = upload(Config, ["TEST-MIB", "TEST-EXT-MIB", "BROKEN-MIB"]),
    Bin = filename:join(MibDir, "TEST-MIB.bin"),
    {ok, Before} = file:read_file_info(Bin, [{time, posix}]),
    ok = stop(),
    %% leftovers of a module deleted elsewhere are removed
    ok = file:write_file(filename:join(MibDir, "GONE-MIB.bin"), <<>>),
    timer:sleep(1100),
    {ok, _} = start(),
    {ok, After} = file:read_file_info(Bin, [{time, posix}]),
    ?assertEqual(element(6, Before), element(6, After)),              % mtime: not recompiled
    ?assertEqual(ok, status(<<"TEST-EXT-MIB">>)),
    ?assertEqual(error, status(<<"BROKEN-MIB">>)),
    {ok, #{messages := [_ | _]}} = s2i_mibs:get(<<"BROKEN-MIB">>),
    ?assertMatch({ok, #{name := <<"testState">>}}, s2i_mibs:lookup(?TEST_STATE)),
    ?assertNot(filelib:is_file(filename:join(MibDir, "GONE-MIB.bin"))),
    %% a lost cache is rebuilt
    ok = stop(),
    [ok = file:delete(F) || F <- filelib:wildcard(filename:join(MibDir, "*"))],
    {ok, _} = start(),
    ?assertEqual(ok, status(<<"TEST-EXT-MIB">>)).

changes_are_audited(Config) ->
    {ok, _} = upload(Config, ["TEST-MIB"]),
    ok = s2i_mibs:delete(<<"TEST-MIB">>, <<"bob">>),
    {atomic, Entries} = mnesia:transaction(fun() -> s2i_config_store:list_audit(10) end),
    ?assertMatch([#{action := mib_delete, kind := mib, name := <<"TEST-MIB">>, actor := <<"bob">>},
                  #{action := mib_put, kind := mib, name := <<"TEST-MIB">>, actor := ?ADMIN}], Entries).
