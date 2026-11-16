-module(s2i_config_SUITE).
-moduledoc "s2i_config: staged edits, activation, versions, audit, persistence (Mnesia).".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([put_get_list_delete/1,
         put_returns_normalised_entity/1,
         invalid_put_stores_nothing/1,
         delete_unknown/1,
         staged_data_survives_restart/1,
         activate_creates_immutable_version/1,
         invalid_config_cannot_be_activated/1,
         activate_without_changes/1,
         has_changes_tracks_staged_vs_active/1,
         subscribers_are_notified_on_activate/1,
         revert_discards_staged_changes/1,
         restore_loads_old_version_into_staged/1,
         audit_log_records_actor_and_action/1,
         export_import_roundtrip_through_json/1,
         invalid_import_is_rejected_entirely/1,
         secrets_are_encrypted_at_rest/1,
         unchanged_secret_is_not_a_change/1,
         foreign_ciphertext_is_rejected/1,
         changed_key_blocks_activation/1,
         insecure_key_file_prevents_start/1]).

all() ->
    [put_get_list_delete,
     put_returns_normalised_entity,
     invalid_put_stores_nothing,
     delete_unknown,
     staged_data_survives_restart,
     activate_creates_immutable_version,
     invalid_config_cannot_be_activated,
     activate_without_changes,
     has_changes_tracks_staged_vs_active,
     subscribers_are_notified_on_activate,
     revert_discards_staged_changes,
     restore_loads_old_version_into_staged,
     audit_log_records_actor_and_action,
     export_import_roundtrip_through_json,
     invalid_import_is_rejected_entirely,
     secrets_are_encrypted_at_rest,
     unchanged_secret_is_not_a_change,
     foreign_ciphertext_is_rejected,
     changed_key_blocks_activation,
     insecure_key_file_prevents_start].

init_per_testcase(TC, Config) ->
    Dir = filename:join(?config(priv_dir, Config), atom_to_list(TC)),
    ok = filelib:ensure_path(Dir),
    ok = application:set_env(mnesia, dir, Dir),
    ok = application:set_env(s2i_core, secret_key_file, key_file(Dir)),
    case TC of
        insecure_key_file_prevents_start -> ok;
        _ -> start_config()
    end,
    [{dir, Dir} | Config].

end_per_testcase(_TC, _Config) ->
    _ = catch stop_config(),
    stopped = mnesia:stop(),
    ok.

key_file(Dir) -> filename:join(Dir, "secret.key").

start_config() ->
    {ok, Pid} = s2i_config:start_link(),
    unlink(Pid),
    ok.

stop_config() ->
    ok = gen_server:stop(s2i_config).

%%% fixtures

-define(ADMIN, <<"admin">>).

server() ->
    #{name => <<"scada1">>, transport => #{kind => tcp}, common_addresses => [1]}.

profile() ->
    #{name => <<"switch24">>, poll_groups => #{<<"status">> => 30000},
      datapoints => [#{name => <<"uptime">>, oid => <<"1.3.6.1.2.1.1.3.0">>,
                       poll_group => <<"status">>,
                       mappings => [#{ioa_offset => 0, type => m_me_nc_1,
                                      transform => #{kind => linear}}]}]}.

device() ->
    #{name => <<"sw-a">>, host => <<"10.0.0.10">>,
      snmp => #{version => v2c, community => <<"public">>},
      profile => <<"switch24">>, ioa_base => 100,
      targets => #{<<"default">> => [#{server => <<"scada1">>, coa => 1}]}}.

stage_valid_config() ->
    {ok, _} = s2i_config:put(server, server(), ?ADMIN),
    {ok, _} = s2i_config:put(profile, profile(), ?ADMIN),
    {ok, _} = s2i_config:put(device, device(), ?ADMIN),
    ok.

%%% tests

put_get_list_delete(_Config) ->
    ?assertEqual([], s2i_config:list(server)),
    {ok, S} = s2i_config:put(server, server(), ?ADMIN),
    ?assertEqual({ok, S}, s2i_config:get(server, <<"scada1">>)),
    ?assertEqual([S], s2i_config:list(server)),
    {ok, S2} = s2i_config:put(server, (server())#{common_addresses => [1, 2]}, ?ADMIN),
    ?assertEqual([S2], s2i_config:list(server)),
    ok = s2i_config:delete(server, <<"scada1">>, ?ADMIN),
    ?assertEqual({error, not_found}, s2i_config:get(server, <<"scada1">>)).

put_returns_normalised_entity(_Config) ->
    {ok, #{transport := #{port := 2404}, params := #{k := 12}}} =
        s2i_config:put(server, #{<<"name">> => <<"scada1">>,
                                 <<"transport">> => #{<<"kind">> => <<"tcp">>},
                                 <<"common_addresses">> => [1]}, ?ADMIN).

invalid_put_stores_nothing(_Config) ->
    {error, [#{path := [common_addresses], error := required}]} =
        s2i_config:put(server, maps:remove(common_addresses, server()), ?ADMIN),
    ?assertEqual([], s2i_config:list(server)),
    {error, [#{error := unknown_kind}]} = s2i_config:put(gizmo, #{}, ?ADMIN).

delete_unknown(_Config) ->
    ?assertEqual({error, not_found}, s2i_config:delete(device, <<"nope">>, ?ADMIN)).

staged_data_survives_restart(_Config) ->
    stage_valid_config(),
    {ok, 1} = s2i_config:activate(?ADMIN, <<"initial">>),
    {ok, _} = s2i_config:put(server, (server())#{common_addresses => [1, 2]}, ?ADMIN),
    Staged = s2i_config:staged(),
    stop_config(),
    stopped = mnesia:stop(),
    start_config(),
    ?assertEqual(Staged, s2i_config:staged()),
    {ok, 1, _} = s2i_config:active().

activate_creates_immutable_version(_Config) ->
    ?assertEqual({error, none}, s2i_config:active()),
    stage_valid_config(),
    {ok, 1} = s2i_config:activate(?ADMIN, <<"initial">>),
    {ok, 1, Active} = s2i_config:active(),
    ?assertEqual(s2i_config:staged(), Active),
    #{servers := #{<<"scada1">> := _}, devices := #{<<"sw-a">> := _}} = Active,
    %% later staged edits do not touch the active version
    ok = s2i_config:delete(device, <<"sw-a">>, ?ADMIN),
    {ok, 1, Active} = s2i_config:active(),
    {ok, 2} = s2i_config:activate(?ADMIN, <<"remove sw-a">>),
    [#{vsn := 2, author := ?ADMIN, comment := <<"remove sw-a">>, at := At2},
     #{vsn := 1, comment := <<"initial">>, at := At1}] = s2i_config:versions(),
    ?assert(At2 >= At1),
    ?assertEqual({ok, Active}, s2i_config:version(1)),
    ?assertEqual({error, not_found}, s2i_config:version(3)).

invalid_config_cannot_be_activated(_Config) ->
    stage_valid_config(),
    {ok, 1} = s2i_config:activate(?ADMIN, <<>>),
    ok = s2i_config:delete(profile, <<"switch24">>, ?ADMIN),
    {error, [#{path := [devices, <<"sw-a">>, profile], error := unknown_profile}]} =
        s2i_config:activate(?ADMIN, <<>>),
    {ok, 1, #{profiles := #{<<"switch24">> := _}}} = s2i_config:active().

activate_without_changes(_Config) ->
    ?assertEqual({error, no_changes}, s2i_config:activate(?ADMIN, <<>>)),
    stage_valid_config(),
    {ok, 1} = s2i_config:activate(?ADMIN, <<>>),
    ?assertEqual({error, no_changes}, s2i_config:activate(?ADMIN, <<>>)).

has_changes_tracks_staged_vs_active(_Config) ->
    ?assertNot(s2i_config:has_changes()),
    stage_valid_config(),
    ?assert(s2i_config:has_changes()),
    {ok, 1} = s2i_config:activate(?ADMIN, <<>>),
    ?assertNot(s2i_config:has_changes()),
    %% re-putting an identical entity is not a change
    {ok, _} = s2i_config:put(server, server(), ?ADMIN),
    ?assertNot(s2i_config:has_changes()).

subscribers_are_notified_on_activate(_Config) ->
    Self = self(),
    Dead = spawn(fun() -> ok = s2i_config:subscribe(), Self ! subscribed end),
    receive subscribed -> ok end,
    ok = s2i_config:subscribe(),
    stage_valid_config(),
    {ok, 1} = s2i_config:activate(?ADMIN, <<>>),
    receive {s2i_config, {activated, 1}} -> ok after 1000 -> ct:fail(no_notification) end,
    ?assertNot(is_process_alive(Dead)),
    ok = s2i_config:unsubscribe(),
    {ok, _} = s2i_config:put(server, (server())#{common_addresses => [1, 2]}, ?ADMIN),
    {ok, 2} = s2i_config:activate(?ADMIN, <<>>),
    receive {s2i_config, _} = Msg -> ct:fail({unexpected, Msg}) after 100 -> ok end.

revert_discards_staged_changes(_Config) ->
    stage_valid_config(),
    ok = s2i_config:revert(?ADMIN),
    ?assertEqual(s2i_validate:empty(), s2i_config:staged()),
    stage_valid_config(),
    {ok, 1} = s2i_config:activate(?ADMIN, <<>>),
    ok = s2i_config:delete(device, <<"sw-a">>, ?ADMIN),
    ok = s2i_config:revert(?ADMIN),
    {ok, 1, Active} = s2i_config:active(),
    ?assertEqual(Active, s2i_config:staged()).

restore_loads_old_version_into_staged(_Config) ->
    stage_valid_config(),
    {ok, 1} = s2i_config:activate(?ADMIN, <<>>),
    {ok, V1} = s2i_config:version(1),
    ok = s2i_config:delete(device, <<"sw-a">>, ?ADMIN),
    {ok, 2} = s2i_config:activate(?ADMIN, <<>>),
    ok = s2i_config:restore(1, ?ADMIN),
    ?assertEqual(V1, s2i_config:staged()),
    ?assertEqual({error, not_found}, s2i_config:restore(9, ?ADMIN)),
    {ok, 3} = s2i_config:activate(?ADMIN, <<"rollback to 1">>).

audit_log_records_actor_and_action(_Config) ->
    {ok, _} = s2i_config:put(server, server(), <<"alice">>),
    {error, _} = s2i_config:put(server, #{}, <<"alice">>),
    ok = s2i_config:delete(server, <<"scada1">>, <<"bob">>),
    [#{actor := <<"bob">>, action := delete, kind := server, name := <<"scada1">>, at := _},
     #{actor := <<"alice">>, action := put, kind := server, name := <<"scada1">>}] =
        s2i_config:audit(10),
    stage_valid_config(),
    {ok, 1} = s2i_config:activate(<<"carol">>, <<"go">>),
    [#{actor := <<"carol">>, action := activate, vsn := 1} | _] = s2i_config:audit(10),
    ?assertEqual(1, length(s2i_config:audit(1))).

export_import_roundtrip_through_json(_Config) ->
    stage_valid_config(),
    Staged = s2i_config:staged(),
    {ok, Exported} = s2i_config:export(staged),
    Json = iolist_to_binary(json:encode(Exported)),
    ok = s2i_config:revert(?ADMIN),
    ?assertEqual(s2i_validate:empty(), s2i_config:staged()),
    ok = s2i_config:import(json:decode(Json), ?ADMIN),
    ?assertEqual(Staged, s2i_config:staged()),
    [#{action := import} | _] = s2i_config:audit(1),
    ?assertEqual({error, none}, s2i_config:export(active)).

invalid_import_is_rejected_entirely(_Config) ->
    stage_valid_config(),
    Before = s2i_config:staged(),
    Bad = #{<<"servers">> => #{<<"x">> => #{<<"name">> => <<"x">>}}},
    {error, [#{path := [servers, <<"x">>, _]} | _]} = s2i_config:import(Bad, ?ADMIN),
    ?assertEqual(Before, s2i_config:staged()),
    %% dangling references are fine in staged config (checked on activate)
    ok = s2i_config:import(#{devices => #{<<"sw-a">> => device()}}, ?ADMIN).

secrets_are_encrypted_at_rest(Config) ->
    Plain = <<"s3cr3t-community">>,
    stage_valid_config(),
    {ok, #{snmp := #{community := Sealed}}} =
        s2i_config:put(device, (device())#{snmp => #{version => v2c, community => Plain}}, ?ADMIN),
    ?assert(s2i_secret:is_sealed(Sealed)),
    ?assertEqual({ok, Plain}, s2i_secret:open(Sealed)),
    {ok, #{snmp := #{community := Sealed}}} = s2i_config:get(device, <<"sw-a">>),
    {ok, 1} = s2i_config:activate(?ADMIN, <<>>),
    {ok, #{devices := #{<<"sw-a">> := #{snmp := #{community := Sealed}}}}} =
        s2i_config:export(active),
    %% nothing Mnesia wrote to disc contains the plaintext
    dumped = mnesia:dump_log(),
    Files = filelib:wildcard(filename:join(?config(dir, Config), "*")),
    ?assert(length(Files) > 3),
    [?assertEqual({F, nomatch}, {F, binary:match(element(2, file:read_file(F)), Plain)})
     || F <- Files, filelib:is_regular(F)].

unchanged_secret_is_not_a_change(_Config) ->
    stage_valid_config(),
    {ok, 1} = s2i_config:activate(?ADMIN, <<>>),
    %% plaintext again: keeps the stored ciphertext
    {ok, _} = s2i_config:put(device, device(), ?ADMIN),
    ?assertNot(s2i_config:has_changes()),
    {ok, #{snmp := #{community := Old}}} = s2i_config:get(device, <<"sw-a">>),
    {ok, #{snmp := #{community := New}}} =
        s2i_config:put(device, (device())#{snmp => #{version => v2c, community => <<"other">>}}, ?ADMIN),
    ?assertNotEqual(Old, New),
    ?assert(s2i_config:has_changes()).

foreign_ciphertext_is_rejected(Config) ->
    %% simulates an export from another installation (other key)
    Other = filename:join(?config(dir, Config), "other.key"),
    ok = s2i_secret:load(Other),
    Foreign = s2i_secret:seal(<<"public">>),
    ok = s2i_secret:load(key_file(?config(dir, Config))),
    Dev = (device())#{snmp => #{version => v2c, community => Foreign}},
    {error, [#{path := [snmp, community], error := wrong_key}]} = s2i_config:put(device, Dev, ?ADMIN),
    {error, [#{path := [devices, <<"sw-a">>, snmp, community], error := wrong_key}]} =
        s2i_config:import(#{devices => #{<<"sw-a">> => Dev}}, ?ADMIN),
    ?assertEqual([], s2i_config:list(device)).

changed_key_blocks_activation(Config) ->
    stage_valid_config(),
    stop_config(),
    ok = file:delete(key_file(?config(dir, Config))),
    start_config(),
    {error, [#{path := [devices, <<"sw-a">>, snmp, community], error := wrong_key}]} =
        s2i_config:activate(?ADMIN, <<>>).

insecure_key_file_prevents_start(Config) ->
    Key = key_file(?config(dir, Config)),
    ok = file:write_file(Key, base64:encode(crypto:strong_rand_bytes(32))),
    ok = file:change_mode(Key, 8#644),
    process_flag(trap_exit, true),
    {error, {insecure_permissions, Key, 8#644}} = s2i_config:start_link(),
    ok = file:change_mode(Key, 8#600),
    start_config().
