-module(s2i_expand_tests).
-include_lib("eunit/include/eunit.hrl").

%%% fixtures (normalised through the schema, as stored)

norm(Kind, M) ->
    {ok, N} = s2i_schema:normalize(Kind, M),
    N.

profile() ->
    norm(profile,
         #{name => <<"switch24">>,
           ioa_stride => 10,
           poll_groups => #{<<"status">> => 30000, <<"counters">> => 60000},
           resolvers => #{<<"if_name">> => #{column => <<"1.3.6.1.2.1.31.1.1.1.1">>}},
           datapoints =>
               [#{name => <<"temperature">>, oid => <<"1.3.6.1.4.1.9.9.13.1.3.1.3.1">>,
                  poll_group => <<"status">>,
                  mappings => [#{ioa_offset => 0, type => m_me_tf_1,
                                 transform => #{kind => linear}}]},
                #{name => <<"if{slot}/operStatus">>,
                  oid => <<"1.3.6.1.2.1.2.2.1.8.{index}">>,
                  scope => instance, poll_group => <<"status">>,
                  mappings => [#{ioa_offset => 1, type => m_sp_tb_1,
                                 transform => #{kind => enum,
                                                map => #{<<"1">> => true, <<"2">> => false}}},
                               #{ioa_offset => 2, type => m_dp_tb_1,
                                 transform => #{kind => enum,
                                                map => #{<<"1">> => on, <<"2">> => off}}}]},
                #{name => <<"if{slot}/inOctets">>,
                  oid => <<"1.3.6.1.2.1.31.1.1.1.6.{index}">>,
                  scope => instance, poll_group => <<"counters">>,
                  mappings => [#{target => <<"counters">>, ioa_offset => 3, type => m_me_tf_1,
                                 transform => #{kind => rate, factor => 8}}]}]}).

device() -> device(<<"sw-a">>, 10000).

device(Name, Base) ->
    norm(device,
         #{name => Name, host => <<"10.0.0.10">>,
           snmp => #{version => v2c, community => <<"public">>},
           profile => <<"switch24">>, ioa_base => Base,
           instances => [#{slot => 1, index => 10101},
                         #{slot => 3, key => #{resolver => <<"if_name">>,
                                               value => <<"Gi1/0/3">>}}],
           targets => #{<<"default">> => [#{server => <<"scada1">>, coa => 1}]}}).

with(Device, Extra) -> norm(device, maps:merge(Device, Extra)).

server(Name, IoaSize) ->
    norm(server, #{name => Name, transport => #{kind => tcp, port => 2404 + IoaSize},
                   common_addresses => [1, 2], params => #{ioa_size => IoaSize}}).

config(Devices) ->
    #{servers => #{<<"scada1">> => server(<<"scada1">>, 3),
                   <<"small">> => server(<<"small">>, 1)},
      profiles => #{<<"switch24">> => profile()},
      devices => maps:from_list([{maps:get(name, D), D} || D <- Devices])}.

expand(D) ->
    {ok, E} = s2i_expand:device(D, profile()),
    E.

dp(Id, #{datapoints := Dps}) ->
    case [Dp || #{id := I} = Dp <- Dps, I =:= Id] of
        [Dp] -> Dp;
        [] -> error({no_datapoint, Id})
    end.

ids(#{datapoints := Dps}) -> [Id || #{id := Id} <- Dps].

ioas(Dp) -> [Ioa || #{ioa := Ioa} <- maps:get(mappings, Dp)].

errors({error, Es}) -> lists:sort([{P, C} || #{path := P, error := C} <- Es]).

%%% expansion

datapoint_ids_are_stable_names_test() ->
    ?assertEqual([<<"sw-a/temperature">>,
                  <<"sw-a/if1/operStatus">>, <<"sw-a/if3/operStatus">>,
                  <<"sw-a/if1/inOctets">>, <<"sw-a/if3/inOctets">>],
                 ids(expand(device()))).

datapoint_carries_template_slot_and_poll_group_test() ->
    E = expand(device()),
    #{template := <<"if{slot}/operStatus">>, slot := 3, poll_group := <<"status">>} =
        dp(<<"sw-a/if3/operStatus">>, E),
    T = dp(<<"sw-a/temperature">>, E),
    ?assertNot(is_map_key(slot, T)).

static_index_is_substituted_test() ->
    E = expand(device()),
    ?assertEqual([1, 3, 6, 1, 2, 1, 2, 2, 1, 8, 10101], maps:get(oid, dp(<<"sw-a/if1/operStatus">>, E))),
    ?assertEqual([1, 3, 6, 1, 4, 1, 9, 9, 13, 1, 3, 1, 3, 1], maps:get(oid, dp(<<"sw-a/temperature">>, E))).

keyed_instance_keeps_template_test() ->
    E = expand(device()),
    ?assertEqual({key, [1, 3, 6, 1, 2, 1, 2, 2, 1, 8], {<<"if_name">>, <<"Gi1/0/3">>}},
                 maps:get(oid, dp(<<"sw-a/if3/operStatus">>, E))).

ioa_formula_test() ->
    E = expand(device()),
    ?assertEqual([10000], ioas(dp(<<"sw-a/temperature">>, E))),
    ?assertEqual([10011, 10012], ioas(dp(<<"sw-a/if1/operStatus">>, E))),
    ?assertEqual([10031, 10032], ioas(dp(<<"sw-a/if3/operStatus">>, E))).

mapping_carries_target_type_and_transform_test() ->
    [#{server := <<"scada1">>, coa := 1, ioa := 10011, type := m_sp_tb_1,
       transform := #{kind := enum}} = M | _] =
        maps:get(mappings, dp(<<"sw-a/if1/operStatus">>, expand(device()))),
    ?assertNot(is_map_key(deadband, M)).

unbound_label_produces_no_mappings_test() ->
    ?assertEqual([], maps:get(mappings, dp(<<"sw-a/if1/inOctets">>, expand(device())))).

label_fans_out_to_all_bindings_test() ->
    D = with(device(), #{targets => #{<<"default">> => [#{server => <<"scada1">>, coa => 1},
                                                         #{server => <<"scada2">>, coa => 7}],
                                     <<"counters">> => [#{server => <<"scada2">>, coa => 7}]}}),
    E = expand(D),
    ?assertEqual([{<<"scada1">>, 1, 10000}, {<<"scada2">>, 7, 10000}],
                 [{S, C, I} || #{server := S, coa := C, ioa := I}
                                   <- maps:get(mappings, dp(<<"sw-a/temperature">>, E))]),
    ?assertEqual([10033], ioas(dp(<<"sw-a/if3/inOctets">>, E))).

no_instances_no_instance_datapoints_test() ->
    ?assertEqual([<<"sw-a/temperature">>], ids(expand(with(device(), #{instances => []})))).

comm_status_point_test() ->
    D = with(device(), #{comm_status => #{server => <<"scada1">>, coa => 1, ioa => 9999}}),
    ?assertEqual(#{server => <<"scada1">>, coa => 1, ioa => 9999, type => m_sp_tb_1},
                 maps:get(comm_status, expand(D))),
    ?assertNot(is_map_key(comm_status, expand(device()))).

%%% overrides

disable_datapoint_for_all_slots_test() ->
    D = with(device(), #{overrides => [#{datapoint => <<"if{slot}/inOctets">>, enabled => false}]}),
    ?assertEqual([<<"sw-a/temperature">>, <<"sw-a/if1/operStatus">>, <<"sw-a/if3/operStatus">>],
                 ids(expand(D))).

disable_datapoint_for_some_slots_test() ->
    D = with(device(), #{overrides => [#{datapoint => <<"if{slot}/operStatus">>,
                                         slots => [3], enabled => false}]}),
    E = expand(D),
    ?assert(lists:member(<<"sw-a/if1/operStatus">>, ids(E))),
    ?assertNot(lists:member(<<"sw-a/if3/operStatus">>, ids(E))).

disable_single_mapping_test() ->
    D = with(device(), #{overrides => [#{datapoint => <<"if{slot}/operStatus">>,
                                         mappings => [#{index => 1, enabled => false}]}]}),
    ?assertEqual([10011], ioas(dp(<<"sw-a/if1/operStatus">>, expand(D)))).

patch_mapping_test() ->
    D = with(device(), #{overrides => [#{datapoint => <<"temperature">>,
                                         mappings => [#{index => 0, type => m_me_nc_1,
                                                        transform => #{kind => linear, scale => 0.1},
                                                        deadband => #{kind => absolute, value => 0.5}}]}]}),
    [#{type := m_me_nc_1, transform := #{scale := 0.1}, deadband := #{value := 0.5},
       ioa := 10000}] = maps:get(mappings, dp(<<"sw-a/temperature">>, expand(D))).

override_errors_test() ->
    Bad = fun(O) -> errors(s2i_expand:device(with(device(), #{overrides => O}), profile())) end,
    ?assertEqual([{[overrides, 0, datapoint], unknown_datapoint}],
                 Bad([#{datapoint => <<"fan">>, enabled => false}])),
    ?assertEqual([{[overrides, 0, slots], not_allowed_for_device_scope}],
                 Bad([#{datapoint => <<"temperature">>, slots => [1]}])),
    ?assertEqual([{[overrides, 0, slots, 1], unknown_slot}],
                 Bad([#{datapoint => <<"if{slot}/operStatus">>, slots => [1, 2]}])),
    ?assertEqual([{[overrides, 0, mappings, 0, index], unknown_mapping}],
                 Bad([#{datapoint => <<"temperature">>, mappings => [#{index => 1}]}])),
    %% the merged mapping must still be consistent (enum cannot feed a measured value)
    ?assertEqual([{[overrides, 0, mappings, 0, type], incompatible_transform}],
                 Bad([#{datapoint => <<"if{slot}/operStatus">>,
                        mappings => [#{index => 0, type => m_me_nc_1}]}])),
    ?assertEqual([{[overrides, 1], duplicate}],
                 Bad([#{datapoint => <<"if{slot}/operStatus">>, slots => [3], enabled => false},
                      #{datapoint => <<"if{slot}/operStatus">>, enabled => false}])),
    %% different slots of the same datapoint are fine
    {ok, _} = s2i_expand:device(
                with(device(), #{overrides => [#{datapoint => <<"if{slot}/operStatus">>, slots => [1], enabled => false},
                                               #{datapoint => <<"if{slot}/operStatus">>, slots => [3], enabled => false}]}),
                profile()).

%%% whole configuration

config_expands_every_device_test() ->
    {ok, #{<<"sw-a">> := #{datapoints := [_ | _]}, <<"sw-b">> := #{datapoints := [_ | _]}}} =
        s2i_expand:config(config([device(), device(<<"sw-b">>, 20000)])).

ioa_collision_between_devices_test() ->
    %% the later device (by name) is reported, pointing at the earlier one
    {error, [#{path := [devices, <<"sw-b">>, datapoints, <<"sw-b/temperature">>, mappings, 0],
               error := ioa_collision,
               detail := #{server := <<"scada1">>, coa := 1, ioa := 10000,
                           with := [devices, <<"sw-a">>, datapoints, <<"sw-a/temperature">>,
                                    mappings, 0]}} | Rest]} =
        s2i_expand:config(config([device(), device(<<"sw-b">>, 10000)])),
    %% every mapping of sw-b collides: temperature + 2 x 2 operStatus
    ?assertEqual(4, length(Rest)).

collisions_are_per_server_and_coa_test() ->
    Other = fun(T) -> with(device(<<"sw-b">>, 10000), #{targets => #{<<"default">> => [T]}}) end,
    {ok, _} = s2i_expand:config(config([device(), Other(#{server => <<"scada1">>, coa => 2})])),
    Cfg = config([device(), Other(#{server => <<"scada2">>, coa => 1})]),
    {ok, _} = s2i_expand:config(Cfg#{servers := (maps:get(servers, Cfg))#{<<"scada2">> => server(<<"scada2">>, 3)}}).

comm_status_collides_with_datapoint_test() ->
    B = with(device(<<"sw-b">>, 20000), #{comm_status => #{server => <<"scada1">>, coa => 1, ioa => 10011}}),
    ?assertEqual([{[devices, <<"sw-b">>, comm_status], ioa_collision}],
                 errors(s2i_expand:config(config([device(), B])))).

ioa_must_fit_server_ioa_size_test() ->
    Small = fun(Base) -> with(device(<<"sw-s">>, Base),
                              #{instances => [], targets => #{<<"default">> => [#{server => <<"small">>, coa => 1}]}}) end,
    {ok, _} = s2i_expand:config(config([Small(255)])),
    ?assertEqual([{[devices, <<"sw-s">>, datapoints, <<"sw-s/temperature">>, mappings, 0], out_of_range}],
                 errors(s2i_expand:config(config([Small(256)])))),
    ?assertEqual([{[devices, <<"sw-s">>, datapoints, <<"sw-s/temperature">>, mappings, 0], out_of_range}],
                 errors(s2i_expand:config(config([Small(0)])))).

device_errors_are_prefixed_test() ->
    D = with(device(), #{overrides => [#{datapoint => <<"fan">>, enabled => false}]}),
    ?assertEqual([{[devices, <<"sw-a">>, overrides, 0, datapoint], unknown_datapoint}],
                 errors(s2i_expand:config(config([D])))).

validate_runs_expansion_test() ->
    Cfg = config([device(), device(<<"sw-b">>, 10000)]),
    {error, [#{error := ioa_collision} | _]} = s2i_validate:config(Cfg).
