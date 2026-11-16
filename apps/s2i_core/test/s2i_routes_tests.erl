-module(s2i_routes_tests).
-include_lib("eunit/include/eunit.hrl").

-define(SYS_UPTIME, [1, 3, 6, 1, 2, 1, 1, 3, 0]).
-define(OPER(I), [1, 3, 6, 1, 2, 1, 2, 2, 1, 8, I]).
-define(IN_OCTETS(I), [1, 3, 6, 1, 2, 1, 31, 1, 1, 1, 6, I]).
-define(TEMP, [1, 3, 6, 1, 4, 1, 9, 9, 13, 1, 3, 1, 3, 1]).

norm(Kind, M) ->
    {ok, N} = s2i_schema:normalize(Kind, M),
    N.

profile() ->
    norm(profile,
         #{name => <<"switch24">>, ioa_stride => 10,
           poll_groups => #{<<"status">> => 30000, <<"counters">> => 60000},
           resolvers => #{<<"if_name">> => #{column => <<"1.3.6.1.2.1.31.1.1.1.1">>}},
           datapoints =>
               [#{name => <<"temperature">>, oid => <<"1.3.6.1.4.1.9.9.13.1.3.1.3.1">>,
                  poll_group => <<"status">>,
                  mappings => [#{ioa_offset => 0, type => m_me_tf_1, transform => #{kind => linear},
                                 deadband => #{kind => absolute, value => 1}}]},
                #{name => <<"if{slot}/operStatus">>, oid => <<"1.3.6.1.2.1.2.2.1.8.{index}">>,
                  scope => instance, poll_group => <<"status">>,
                  mappings => [#{ioa_offset => 1, type => m_sp_tb_1,
                                 transform => #{kind => enum, map => #{<<"1">> => true, <<"2">> => false}}}]},
                #{name => <<"if{slot}/inOctets">>, oid => <<"1.3.6.1.2.1.31.1.1.1.6.{index}">>,
                  scope => instance, poll_group => <<"counters">>,
                  mappings => [#{target => <<"counters">>, ioa_offset => 2, type => m_me_tf_1,
                                 transform => #{kind => rate}}]},
                %% trap-only: no poll group
                #{name => <<"if{slot}/adminStatus">>, oid => <<"1.3.6.1.2.1.2.2.1.7.{index}">>,
                  scope => instance,
                  mappings => [#{ioa_offset => 3, type => m_sp_tb_1,
                                 transform => #{kind => enum, map => #{<<"1">> => true}, default => false}}]}]}).

device(Targets) ->
    norm(device,
         #{name => <<"sw-a">>, host => <<"10.0.0.10">>,
           snmp => #{version => v2c, community => <<"public">>},
           profile => <<"switch24">>, ioa_base => 10000,
           instances => [#{slot => 1, index => 10101},
                         #{slot => 3, key => #{resolver => <<"if_name">>, value => <<"Gi1/0/3">>}}],
           targets => Targets,
           comm_status => #{server => <<"scada1">>, coa => 1, ioa => 9999}}).

all_targets() ->
    #{<<"default">> => [#{server => <<"scada1">>, coa => 1}],
      <<"counters">> => [#{server => <<"scada1">>, coa => 1}]}.

expansion(Targets) ->
    {ok, E} = s2i_expand:device(device(Targets), profile()),
    E.

resolved() -> #{<<"if_name">> => #{<<"Gi1/0/3">> => 10103}}.

compile() -> s2i_routes:device(expansion(all_targets()), resolved()).

%%% device routes

routes_by_concrete_oid_test() ->
    #{routes := Routes} = compile(),
    ?assertEqual(lists:sort([?TEMP, ?OPER(10101), ?OPER(10103), ?IN_OCTETS(10101), ?IN_OCTETS(10103),
                             [1, 3, 6, 1, 2, 1, 2, 2, 1, 7, 10101], [1, 3, 6, 1, 2, 1, 2, 2, 1, 7, 10103]]),
                 lists:sort(maps:keys(Routes))),
    ?assertEqual([#{datapoint => <<"sw-a/if3/operStatus">>, server => <<"scada1">>, coa => 1,
                    ioa => 10031, type => m_sp_tb_1,
                    transform => #{kind => enum, map => #{<<"1">> => true, <<"2">> => false}}}],
                 maps:get(?OPER(10103), Routes)),
    [#{deadband := #{kind := absolute}}] = maps:get(?TEMP, Routes).

poll_groups_include_sys_uptime_test() ->
    #{polls := Polls} = compile(),
    ?assertEqual(#{<<"status">> => lists:sort([?SYS_UPTIME, ?TEMP, ?OPER(10101), ?OPER(10103)]),
                   <<"counters">> => lists:sort([?SYS_UPTIME, ?IN_OCTETS(10101), ?IN_OCTETS(10103)])},
                 Polls).

datapoints_without_mappings_are_not_polled_test() ->
    %% "counters" not bound: inOctets has no mapping, its poll group disappears
    #{polls := Polls, routes := Routes} =
        s2i_routes:device(expansion(#{<<"default">> => [#{server => <<"scada1">>, coa => 1}]}), resolved()),
    ?assertEqual([<<"status">>], maps:keys(Polls)),
    ?assertNot(is_map_key(?IN_OCTETS(10101), Routes)).

unresolved_instances_are_reported_not_guessed_test() ->
    #{routes := Routes, polls := #{<<"status">> := Status}, unresolved := Unresolved} =
        s2i_routes:device(expansion(all_targets()), #{}),
    ?assertEqual([<<"sw-a/if3/operStatus">>, <<"sw-a/if3/inOctets">>, <<"sw-a/if3/adminStatus">>],
                 [Id || #{id := Id} <- Unresolved]),
    %% the unresolved datapoints keep their mappings (published as invalid)
    [#{mappings := [#{ioa := 10031}]} | _] = Unresolved,
    ?assertNot(lists:member(?OPER(10103), Status)),
    ?assertNot(is_map_key(?OPER(10103), Routes)),
    #{unresolved := []} = compile().

templates_find_datapoints_for_trap_rules_test() ->
    T = maps:get(templates, compile()),
    ?assertEqual(?TEMP, maps:get({<<"temperature">>, device}, T)),
    ?assertEqual(?OPER(10103), maps:get({<<"if{slot}/operStatus">>, 10103}, T)),
    ?assertEqual([1, 3, 6, 1, 2, 1, 2, 2, 1, 7, 10101], maps:get({<<"if{slot}/adminStatus">>, 10101}, T)),
    %% unresolved instances and datapoints without mappings are not there
    T2 = maps:get(templates, s2i_routes:device(expansion(#{<<"default">> => [#{server => <<"scada1">>, coa => 1}]}),
                                               #{})),
    ?assertNot(is_map_key({<<"if{slot}/operStatus">>, 10103}, T2)),
    ?assertNot(is_map_key({<<"if{slot}/inOctets">>, 10101}, T2)),
    ?assert(is_map_key({<<"if{slot}/operStatus">>, 10101}, T2)).

shared_oid_collects_all_routes_test() ->
    E = expansion(all_targets()),
    #{datapoints := [Temp | _]} = E,
    Twin = Temp#{id => <<"sw-a/temperature2">>,
                 mappings => [M#{ioa => 10005} || M <- maps:get(mappings, Temp)]},
    #{routes := Routes} = s2i_routes:device(E#{datapoints := [Temp, Twin | tl(maps:get(datapoints, E))]},
                                            resolved()),
    ?assertEqual([10000, 10005], [I || #{ioa := I} <- maps:get(?TEMP, Routes)]).

comm_status_is_passed_through_test() ->
    #{comm_status := #{server := <<"scada1">>, ioa := 9999}} = compile().

%%% points per server

points_per_server_test() ->
    E = expansion(all_targets()),
    Two = #{datapoints => [#{id => <<"sw-b/temperature">>, template => <<"temperature">>,
                             oid => ?TEMP,
                             mappings => [#{server => <<"scada2">>, coa => 5, ioa => 1,
                                            type => m_me_nc_1, transform => #{kind => linear}}]}]},
    Points = s2i_routes:points(#{<<"sw-a">> => E, <<"sw-b">> => Two}),
    ?assertEqual([<<"scada1">>, <<"scada2">>], lists:sort(maps:keys(Points))),
    #{<<"scada1">> := S1, <<"scada2">> := S2} = Points,
    ?assertEqual(#{{5, 1} => #{type => m_me_nc_1, source => {datapoint, <<"sw-b/temperature">>}}}, S2),
    %% every address is reserved, also those of unresolved instances, plus comm status
    ?assertEqual(#{type => m_sp_tb_1, source => {datapoint, <<"sw-a/if3/operStatus">>}},
                 maps:get({1, 10031}, S1)),
    ?assertEqual(#{type => m_sp_tb_1, source => {comm_status, <<"sw-a">>}}, maps:get({1, 9999}, S1)),
    ?assertEqual(1 + 3 * 2 + 1, map_size(S1)).
