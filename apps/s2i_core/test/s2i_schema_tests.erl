-module(s2i_schema_tests).

-include_lib("eunit/include/eunit.hrl").

%%% ---------------------------------------------------------------------------
%%% helpers
%%% ---------------------------------------------------------------------------

ok(Kind, Input) ->
    case s2i_schema:normalize(Kind, Input) of
        {ok, Norm} -> Norm;
        {error, Errors} -> error({unexpected_errors, Errors})
    end.

errors(Kind, Input) ->
    {error, Errors} = s2i_schema:normalize(Kind, Input),
    lists:sort([{P, C} || #{path := P, error := C} <- Errors]).

has_error(Path, Code, Kind, Input) ->
    lists:member({Path, Code}, errors(Kind, Input)).

server() ->
    #{name => <<"scada1">>,
      transport => #{kind => tcp},
      common_addresses => [1]}.

device() ->
    #{name => <<"core-sw1">>,
      host => <<"10.0.0.10">>,
      snmp => #{version => v2c, community => <<"public">>},
      profile => <<"switch24">>,
      ioa_base => 10000}.

profile() ->
    #{name => <<"switch24">>,
      ioa_stride => 10,
      poll_groups => #{<<"status">> => 30000},
      resolvers => #{<<"if_name">> => #{column => <<"1.3.6.1.2.1.31.1.1.1.1">>}},
      datapoints =>
          [#{name => <<"if{slot}/operStatus">>,
             oid => <<"1.3.6.1.2.1.2.2.1.8.{index}">>,
             scope => instance,
             poll_group => <<"status">>,
             mappings => [#{ioa_offset => 1, type => m_sp_tb_1,
                            transform => #{kind => enum,
                                           map => #{<<"1">> => true, <<"2">> => false}}}]},
           #{name => <<"temperature">>,
             oid => <<"1.3.6.1.4.1.9.9.13.1.3.1.3.1">>,
             poll_group => <<"status">>,
             mappings => [#{ioa_offset => 0, type => m_me_tf_1,
                            transform => #{kind => linear, scale => 0.1}}]}]}.

%%% ---------------------------------------------------------------------------
%%% generic behaviour
%%% ---------------------------------------------------------------------------

not_a_map_test() ->
    ?assertEqual([{[], invalid_type}], errors(server, [])).

binary_keys_and_enum_values_are_accepted_test() ->
    Json = #{<<"name">> => <<"scada1">>,
             <<"transport">> => #{<<"kind">> => <<"tcp">>, <<"port">> => 2405},
             <<"common_addresses">> => [1]},
    #{name := <<"scada1">>, transport := #{kind := tcp, port := 2405}} = ok(server, Json).

null_is_treated_as_absent_test() ->
    #{redundancy := #{mode := connection}} =
        ok(server, (server())#{redundancy => null}).

unknown_field_is_rejected_test() ->
    ?assert(has_error([<<"colour">>], unknown_field, server, (server())#{<<"colour">> => 1})),
    ?assert(has_error([colour], unknown_field, server, (server())#{colour => 1})).

missing_required_field_test() ->
    ?assert(has_error([common_addresses], required, server,
                      maps:remove(common_addresses, server()))).

all_errors_are_reported_not_only_the_first_test() ->
    Bad = #{name => <<"bad name!">>, transport => #{kind => udp}, common_addresses => []},
    ?assertEqual([{[common_addresses], too_short},
                  {[name], invalid_name},
                  {[transport, kind], invalid_value}],
                 errors(server, Bad)).

unknown_kind_test() ->
    ?assertEqual({error, [#{path => [], error => unknown_kind}]},
                 s2i_schema:normalize(gizmo, #{})).

normalize_is_idempotent_test_() ->
    [?_assertEqual(ok(K, ok(K, In)), ok(K, In))
     || {K, In} <- [{server, server()}, {device, device()}, {profile, profile()}]].

%%% ---------------------------------------------------------------------------
%%% names
%%% ---------------------------------------------------------------------------

name_rules_test_() ->
    Valid = [<<"a">>, <<"core-sw1">>, <<"A_b.c-1">>, binary:copy(<<"x">>, 64)],
    Invalid = [<<>>, <<"-lead">>, <<"has space">>, <<"slash/no">>,
               binary:copy(<<"x">>, 65), 42],
    [?_assertMatch(#{name := _}, ok(server, (server())#{name => N})) || N <- Valid] ++
    [?_assert(has_error([name], invalid_name, server, (server())#{name => N})) || N <- Invalid].

string_name_is_converted_to_binary_test() ->
    #{name := <<"scada1">>} = ok(server, (server())#{name => "scada1"}).

%%% ---------------------------------------------------------------------------
%%% server
%%% ---------------------------------------------------------------------------

server_defaults_test() ->
    #{transport := #{kind := tcp, port := 2404, ip := <<"0.0.0.0">>},
      params := #{k := 12, w := 8, t1 := 15000, t2 := 10000, t3 := 20000,
                  coa_size := 2, ioa_size := 3, cot_size := 2},
      redundancy := #{mode := connection, buffer := 1000, groups := []}} = S =
        ok(server, server()),
    ?assertNot(maps:is_key(background_scan, S)).

tls_transport_test() ->
    Tls = #{kind => tls, certfile => <<"/etc/s2i/server.pem">>,
            keyfile => <<"/etc/s2i/server.key">>, cacertfile => <<"/etc/s2i/ca.pem">>},
    #{transport := #{kind := tls, port := 19998, verify := true}} =
        ok(server, (server())#{transport => Tls}),
    ?assert(has_error([transport, certfile], required, server,
                      (server())#{transport => maps:remove(certfile, Tls)})).

tcp_transport_rejects_tls_fields_test() ->
    ?assert(has_error([transport, certfile], unknown_field, server,
                      (server())#{transport => #{kind => tcp, certfile => <<"x">>}})).

listen_ip_is_canonicalised_test() ->
    #{transport := #{ip := <<"::1">>}} =
        ok(server, (server())#{transport => #{kind => tcp, ip => <<"0:0:0:0:0:0:0:1">>}}),
    ?assert(has_error([transport, ip], invalid_format, server,
                      (server())#{transport => #{kind => tcp, ip => <<"10.0.0.300">>}})).

port_range_test() ->
    ?assert(has_error([transport, port], out_of_range, server,
                      (server())#{transport => #{kind => tcp, port => 70000}})),
    ?assert(has_error([transport, port], invalid_type, server,
                      (server())#{transport => #{kind => tcp, port => <<"2404">>}})).

w_must_not_exceed_two_thirds_of_k_test() ->
    #{params := #{k := 12, w := 8}} = ok(server, (server())#{params => #{k => 12, w => 8}}),
    ?assert(has_error([params, w], w_too_large, server,
                      (server())#{params => #{k => 12, w => 9}})).

t2_must_be_below_t1_test() ->
    ?assert(has_error([params, t2], t2_not_below_t1, server,
                      (server())#{params => #{t1 => 10000, t2 => 10000}})).

common_addresses_test() ->
    ?assert(has_error([common_addresses, 1], duplicate, server,
                      (server())#{common_addresses => [1, 1]})),
    ?assert(has_error([common_addresses, 0], out_of_range, server,
                      (server())#{common_addresses => [65535]})),
    %% one-octet COA: 255 is broadcast
    ?assert(has_error([common_addresses, 0], out_of_range, server,
                      (server())#{common_addresses => [255],
                                  params => #{coa_size => 1}})).

redundancy_multiple_test() ->
    Groups = [#{name => <<"scada_a">>, match => [<<"10.0.0.0/24">>], buffer => 5000},
              #{name => <<"scada_b">>, match => [<<"10.1.0.5/32">>, <<"fd00::/8">>]}],
    #{redundancy := #{mode := multiple, groups := [_, _]}} =
        ok(server, (server())#{redundancy => #{mode => multiple, groups => Groups}}),
    ?assert(has_error([redundancy, groups], required_for_multiple, server,
                      (server())#{redundancy => #{mode => multiple}})),
    ?assert(has_error([redundancy, groups], only_for_multiple, server,
                      (server())#{redundancy => #{mode => single, groups => Groups}})),
    ?assert(has_error([redundancy, groups, 1, name], duplicate, server,
                      (server())#{redundancy => #{mode => multiple,
                                                  groups => [hd(Groups), hd(Groups)]}})).

cidr_test_() ->
    Srv = fun(C) -> (server())#{redundancy =>
                                    #{mode => multiple,
                                      groups => [#{name => <<"g">>, match => [C]}]}} end,
    Path = [redundancy, groups, 0, match, 0],
    [?_assert(has_error(Path, invalid_format, server, Srv(C)))
     || C <- [<<"10.0.0.0">>, <<"10.0.0.0/33">>, <<"fd00::/129">>, <<"x/8">>, <<"10.0.0.0/-1">>]].

%%% ---------------------------------------------------------------------------
%%% device
%%% ---------------------------------------------------------------------------

device_defaults_test() ->
    #{enabled := true, port := 161, timeout := 2000, retries := 1,
      max_varbinds := 30, down_after := 3, instances := [], targets := #{},
      snmp := #{version := v2c, community := <<"public">>}} = ok(device, device()).

host_test_() ->
    [?_assertMatch(#{host := H}, ok(device, (device())#{host => H}))
     || H <- [<<"10.0.0.1">>, <<"fd00::1">>, <<"sw1.example.net">>, <<"sw-1">>]] ++
    [?_assert(has_error([host], invalid_format, device, (device())#{host => H}))
     || H <- [<<>>, <<"-sw">>, <<"sw_1.example">>, <<"a..b">>]].

v1_and_v2c_require_community_test() ->
    ?assert(has_error([snmp, community], required, device,
                      (device())#{snmp => #{version => v1}})).

v3_test() ->
    V3 = #{version => v3, user => <<"monitor">>, sec_level => auth_priv,
           auth_protocol => sha256, auth_password => <<"authpass1">>,
           priv_protocol => aes, priv_password => <<"privpass1">>,
           engine_id => <<"80:00:00:09:03:00:AA:BB:CC">>},
    #{snmp := #{engine_id := <<"800000090300aabbcc">>}} = ok(device, (device())#{snmp => V3}),
    ?assert(has_error([snmp, priv_password], required, device,
                      (device())#{snmp => maps:remove(priv_password, V3)})),
    ?assert(has_error([snmp, auth_password], too_short, device,
                      (device())#{snmp => V3#{auth_password => <<"short">>}})),
    NoAuth = #{version => v3, user => <<"monitor">>, sec_level => no_auth_no_priv},
    _ = ok(device, (device())#{snmp => NoAuth}),
    ?assert(has_error([snmp, auth_protocol], not_allowed_for_sec_level, device,
                      (device())#{snmp => NoAuth#{auth_protocol => sha}})),
    ?assert(has_error([snmp, community], unknown_field, device,
                      (device())#{snmp => NoAuth#{community => <<"public">>}})).

engine_id_format_test_() ->
    Snmp = fun(E) -> #{version => v3, user => <<"u">>, sec_level => no_auth_no_priv,
                       engine_id => E} end,
    [?_assert(has_error([snmp, engine_id], invalid_format, device,
                        (device())#{snmp => Snmp(E)}))
     || E <- [<<"8000">>, <<"80000009030000aabbc">>, <<"zz000009030000aabbcc">>,
              binary:copy(<<"ab">>, 33)]].

instances_test() ->
    Insts = [#{slot => 1, index => 10101},
             #{slot => 2, key => #{resolver => <<"if_name">>, value => <<"Gi1/0/2">>}}],
    #{instances := [_, _]} = ok(device, (device())#{instances => Insts}),
    ?assert(has_error([instances, 0], index_or_key_required, device,
                      (device())#{instances => [#{slot => 1}]})),
    ?assert(has_error([instances, 0], index_and_key_exclusive, device,
                      (device())#{instances => [(hd(Insts))#{key => #{resolver => <<"r">>,
                                                                   value => <<"v">>}}]})),
    ?assert(has_error([instances, 1, slot], duplicate, device,
                      (device())#{instances => [hd(Insts), (hd(Insts))#{index => 5}]})),
    ?assert(has_error([instances, 1, index], duplicate, device,
                      (device())#{instances => [hd(Insts), (hd(Insts))#{slot => 7}]})),
    ?assert(has_error([instances, 1, key], duplicate, device,
                      (device())#{instances => [lists:last(Insts),
                                                (lists:last(Insts))#{slot => 7}]})).

targets_and_comm_status_test() ->
    D = (device())#{targets => #{<<"default">> => [#{server => <<"scada1">>, coa => 1},
                                                   #{server => <<"scada2">>, coa => 7}]},
                    comm_status => #{server => <<"scada1">>, coa => 1, ioa => 9999}},
    #{targets := #{<<"default">> := [_, _]},
      comm_status := #{type := m_sp_tb_1}} = ok(device, D),
    ?assert(has_error([targets, <<"default">>], too_short, device,
                      (device())#{targets => #{<<"default">> => []}})),
    ?assert(has_error([targets, <<"default">>, 1], duplicate, device,
                      (device())#{targets => #{<<"default">> =>
                                                   [#{server => <<"s">>, coa => 1},
                                                    #{server => <<"s">>, coa => 1}]}})),
    ?assert(has_error([comm_status, type], invalid_value, device,
                      D#{comm_status => #{server => <<"scada1">>, coa => 1, ioa => 1,
                                          type => m_me_nc_1}})).

%%% ---------------------------------------------------------------------------
%%% profile
%%% ---------------------------------------------------------------------------

profile_normalises_test() ->
    #{datapoints := [#{scope := instance,
                       mappings := [#{target := <<"default">>,
                                      transform := #{kind := enum}}]},
                     #{scope := device,
                       mappings := [#{transform := #{kind := linear, scale := 0.1,
                                                     offset := 0}}]}]} =
        ok(profile, profile()).

oid_test_() ->
    Dp = fun(Oid) -> (profile())#{datapoints => [#{name => <<"x">>, oid => Oid}]} end,
    [?_assertMatch(#{datapoints := [#{oid := <<"1.3.6.1.2.1.1.3.0">>}]},
                   ok(profile, Dp(<<".1.3.6.1.2.1.1.3.0">>)))] ++
    [?_assert(has_error([datapoints, 0, oid], invalid_format, profile, Dp(O)))
     || O <- [<<"1">>, <<"3.6.1">>, <<"1.3.x.1">>, <<"1.3..6">>, <<"1.3.6.{slot}">>,
              <<"1.3.{index}.6">>]].

poll_group_reference_test() ->
    P = profile(),
    [Dp | Rest] = maps:get(datapoints, P),
    ?assert(has_error([datapoints, 0, poll_group], unknown_poll_group, profile,
                      P#{datapoints => [Dp#{poll_group => <<"nope">>} | Rest]})).

poll_interval_range_test() ->
    ?assert(has_error([poll_groups, <<"fast">>], out_of_range, profile,
                      (profile())#{poll_groups => #{<<"fast">> => 100}})).

scope_placeholders_test() ->
    P = profile(),
    [Inst, Dev] = maps:get(datapoints, P),
    ?assert(has_error([datapoints, 0, oid], index_placeholder_required, profile,
                      P#{datapoints => [Inst#{oid => <<"1.3.6.1.2.1.2.2.1.8">>}, Dev]})),
    ?assert(has_error([datapoints, 0, name], slot_placeholder_required, profile,
                      P#{datapoints => [Inst#{name => <<"operStatus">>}, Dev]})),
    ?assert(has_error([datapoints, 1, oid], index_placeholder_not_allowed, profile,
                      P#{datapoints => [Inst, Dev#{oid => <<"1.3.6.1.4.1.9.{index}">>}]})),
    ?assert(has_error([datapoints, 1, name], slot_placeholder_not_allowed, profile,
                      P#{datapoints => [Inst, Dev#{name => <<"t{slot}">>}]})).

datapoint_names_unique_test() ->
    P = profile(),
    [_, Dev] = maps:get(datapoints, P),
    ?assert(has_error([datapoints, 1, name], duplicate, profile,
                      P#{datapoints => [Dev, Dev]})).

instance_offset_must_fit_stride_test() ->
    P = profile(),
    ?assert(has_error([datapoints, 0, mappings, 0, ioa_offset], offset_exceeds_stride,
                      profile, P#{ioa_stride => 1})).

duplicate_ioa_offset_test() ->
    P = profile(),
    [Inst, Dev] = maps:get(datapoints, P),
    Dev2 = Dev#{name => <<"temperature2">>},
    ?assert(has_error([datapoints, 2, mappings, 0, ioa_offset], duplicate, profile,
                      P#{datapoints => [Inst, Dev, Dev2]})),
    %% same offset is fine for another target label
    [M] = maps:get(mappings, Dev2),
    _ = ok(profile, P#{datapoints => [Inst, Dev,
                                      Dev2#{mappings => [M#{target => <<"other">>}]}]}).

%%% ---------------------------------------------------------------------------
%%% mappings: transforms, type compatibility, deadband
%%% ---------------------------------------------------------------------------

mapping_profile(M) ->
    (profile())#{datapoints => [#{name => <<"x">>, oid => <<"1.3.6.1.2.1.1.3.0">>,
                                  mappings => [M]}]}.

mapping_errors(M) -> errors(profile, mapping_profile(M)).

-define(MP, [datapoints, 0, mappings, 0]).

transform_kinds_test_() ->
    Ok = [{m_me_nc_1, #{kind => linear}},
          {m_sp_na_1, #{kind => enum, map => #{<<"1">> => true}}},
          {m_dp_tb_1, #{kind => enum, map => #{<<"1">> => on, <<"2">> => off},
                        default => faulty}},
          {m_st_na_1, #{kind => enum, map => #{<<"-3">> => -3}}},
          {m_sp_tb_1, #{kind => bit, bit => 3}},
          {m_sp_na_1, #{kind => threshold, op => gt, limit => 70}},
          {m_it_tb_1, #{kind => counter}},
          {m_me_tf_1, #{kind => rate, factor => 8}}],
    [?_assertMatch(#{}, ok(profile, mapping_profile(#{ioa_offset => 0, type => T,
                                                      transform => Tr})))
     || {T, Tr} <- Ok].

incompatible_type_test_() ->
    Bad = [{m_sp_na_1, #{kind => linear}},
           {m_me_nc_1, #{kind => counter}},
           {m_it_na_1, #{kind => rate}},
           {m_me_na_1, #{kind => bit, bit => 0}},
           {m_dp_na_1, #{kind => threshold, op => lt, limit => 1}}],
    [?_assert(lists:member({?MP ++ [type], incompatible_transform},
                           mapping_errors(#{ioa_offset => 0, type => T, transform => Tr})))
     || {T, Tr} <- Bad].

enum_values_must_match_type_test_() ->
    Cases = [{m_sp_na_1, #{<<"1">> => on}},
             {m_dp_na_1, #{<<"1">> => true}},
             {m_st_na_1, #{<<"1">> => 64}},
             {m_st_na_1, #{<<"1">> => true}}],
    [?_assert(lists:member({?MP ++ [transform, map, <<"1">>], invalid_state},
                           mapping_errors(#{ioa_offset => 0, type => T,
                                            transform => #{kind => enum, map => Map}})))
     || {T, Map} <- Cases].

enum_keys_must_be_integers_test() ->
    ?assert(lists:member({?MP ++ [transform, map, <<"up">>], invalid_format},
                         mapping_errors(#{ioa_offset => 0, type => m_sp_na_1,
                                          transform => #{kind => enum,
                                                         map => #{<<"up">> => true}}}))).

enum_keys_are_canonicalised_test() ->
    #{datapoints := [#{mappings := [#{transform := #{map := Map}}]}]} =
        ok(profile, mapping_profile(#{ioa_offset => 0, type => m_sp_na_1,
                                      transform => #{kind => enum,
                                                     map => #{<<"+01">> => true}}})),
    ?assertEqual(#{<<"1">> => true}, Map).

bit_range_test() ->
    ?assert(lists:member({?MP ++ [transform, bit], out_of_range},
                         mapping_errors(#{ioa_offset => 0, type => m_sp_na_1,
                                          transform => #{kind => bit, bit => 64}}))).

deadband_test() ->
    Base = #{ioa_offset => 0, type => m_me_nc_1, transform => #{kind => linear}},
    _ = ok(profile, mapping_profile(Base#{deadband => #{kind => percent, value => 0.5}})),
    ?assert(lists:member({?MP ++ [deadband, value], out_of_range},
                         mapping_errors(Base#{deadband => #{kind => absolute, value => -1}}))),
    ?assert(lists:member({?MP ++ [deadband], not_applicable},
                         mapping_errors(#{ioa_offset => 0, type => m_sp_na_1,
                                          transform => #{kind => bit, bit => 0},
                                          deadband => #{kind => absolute, value => 1}}))).

sealed_secrets_skip_plaintext_rules_test() ->
    %% ciphertext from s2i_secret (opaque to the schema); length rules apply
    %% to plaintext only, decryptability is checked by s2i_secret.
    Sealed = <<"enc:v1:0011aabb:", (base64:encode(<<0:(8*40)>>))/binary>>,
    V3 = #{version => v3, user => <<"u">>, sec_level => auth_priv,
           auth_protocol => sha, auth_password => Sealed,
           priv_protocol => aes, priv_password => Sealed},
    #{snmp := #{auth_password := Sealed}} = ok(device, (device())#{snmp => V3}),
    #{snmp := #{community := Sealed}} =
        ok(device, (device())#{snmp => #{version => v2c, community => Sealed}}).

malformed_sealed_secret_test_() ->
    [?_assert(has_error([snmp, community], invalid_format, device,
                        (device())#{snmp => #{version => v2c, community => Bad}}))
     || Bad <- [<<"enc:v1:">>, <<"enc:v1:xyz">>, <<"enc:v1:0011aabb:">>,
                <<"enc:v1:0011aabb:!!">>, <<"enc:v9:0011aabb:AAAA">>]].

%%% device overrides (phase 2)

overrides_default_to_empty_test() ->
    #{overrides := []} = ok(device, device()).

override_canonical_form_test() ->
    #{overrides := [#{datapoint := <<"if{slot}/operStatus">>, slots := [1, 3],
                      enabled := true,
                      mappings := [#{index := 0, enabled := false}]}]} =
        ok(device, (device())#{overrides =>
                                   [#{<<"datapoint">> => <<"if{slot}/operStatus">>,
                                      <<"slots">> => [1, 3],
                                      <<"mappings">> => [#{<<"index">> => 0,
                                                           <<"enabled">> => false}]}]}).

override_mapping_patch_test() ->
    Patch = #{index => 1, type => m_me_tf_1,
              transform => #{kind => linear, scale => 0.1},
              deadband => #{kind => percent, value => 5}},
    #{overrides := [#{mappings := [#{transform := #{scale := 0.1, offset := 0},
                                     enabled := true}]}]} =
        ok(device, (device())#{overrides => [#{datapoint => <<"temperature">>,
                                               mappings => [Patch]}]}).

override_errors_test_() ->
    D = fun(O) -> (device())#{overrides => [O]} end,
    [?_assert(has_error([overrides, 0, datapoint], required, device, D(#{enabled => false}))),
     ?_assert(has_error([overrides, 0, slots], too_short, device,
                        D(#{datapoint => <<"x">>, slots => []}))),
     ?_assert(has_error([overrides, 0, slots, 1], duplicate, device,
                        D(#{datapoint => <<"x">>, slots => [1, 1]}))),
     ?_assert(has_error([overrides, 0, mappings, 1, index], duplicate, device,
                        D(#{datapoint => <<"x">>, mappings => [#{index => 0}, #{index => 0}]}))),
     ?_assert(has_error([overrides, 0, mappings, 0, type], invalid_value, device,
                        D(#{datapoint => <<"x">>, mappings => [#{index => 0, type => c_sc_na_1}]})))].
