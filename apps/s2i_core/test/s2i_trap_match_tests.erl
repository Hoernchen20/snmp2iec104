-module(s2i_trap_match_tests).
-include_lib("eunit/include/eunit.hrl").

-define(LINK_DOWN, [1, 3, 6, 1, 6, 3, 1, 1, 5, 3]).
-define(COLD_START, [1, 3, 6, 1, 6, 3, 1, 1, 5, 1]).
-define(SNMP_TRAP_OID, [1, 3, 6, 1, 6, 3, 1, 1, 4, 1, 0]).
-define(SYS_UPTIME, [1, 3, 6, 1, 2, 1, 1, 3, 0]).
-define(IF_INDEX(I), [1, 3, 6, 1, 2, 1, 2, 2, 1, 1, I]).
-define(ADMIN(I), [1, 3, 6, 1, 2, 1, 2, 2, 1, 7, I]).
-define(OPER(I), [1, 3, 6, 1, 2, 1, 2, 2, 1, 8, I]).
-define(ENT, [1, 3, 6, 1, 4, 1, 99999]).
-define(TEMP, ?ENT ++ [1, 0]).
-define(ALARM, ?ENT ++ [5, 0]).

vb(Oid, Type, Value) -> {varbind, Oid, Type, Value, 1}.

%%% normalisation

v2_trap_test() ->
    T = s2i_trap_match:normalize(
          {noError, 0, [vb(?SYS_UPTIME, 'TimeTicks', 4711),
                        vb(?SNMP_TRAP_OID, 'OBJECT IDENTIFIER', ?LINK_DOWN),
                        vb(?IF_INDEX(5), 'INTEGER', 5),
                        vb(?OPER(5), 'INTEGER', 2)]}),
    ?assertEqual(#{trap_oid => ?LINK_DOWN,
                   varbinds => [{?IF_INDEX(5), {integer, 5}}, {?OPER(5), {integer, 2}}]}, T).

v2_trap_without_trap_oid_test() ->
    #{trap_oid := undefined} = s2i_trap_match:normalize({noError, 0, []}).

v1_generic_trap_test() ->
    %% RFC 3584 §3.1: linkDown is generic 2 → snmpTraps.3
    T = s2i_trap_match:normalize({[1, 3, 6, 1, 4, 1, 9], 2, 0, 100, [vb(?IF_INDEX(5), 'INTEGER', 5)]}),
    ?assertEqual(#{trap_oid => ?LINK_DOWN, varbinds => [{?IF_INDEX(5), {integer, 5}}]}, T),
    #{trap_oid := ?COLD_START} = s2i_trap_match:normalize({?ENT, 0, 0, 100, []}).

v1_enterprise_specific_trap_test() ->
    #{trap_oid := T} = s2i_trap_match:normalize({?ENT, 6, 17, 100, []}),
    ?assertEqual(?ENT ++ [0, 17], T).

%%% matching

lookup() ->
    #{routes => #{?OPER(5) => [r], ?OPER(6) => [r], ?TEMP => [r], ?ALARM => [r]},
      templates => #{{<<"if{slot}/oper">>, 5} => ?OPER(5), {<<"if{slot}/oper">>, 6} => ?OPER(6),
                     {<<"temperature">>, device} => ?TEMP, {<<"alarm">>, device} => ?ALARM}}.

rules(Rules) ->
    {ok, #{trap_rules := Rs}} =
        s2i_schema:normalize(profile, #{name => <<"p">>, ioa_stride => 10,
                                        datapoints => [#{name => <<"if{slot}/oper">>, scope => instance,
                                                         oid => <<"1.3.6.1.2.1.2.2.1.8.{index}">>},
                                                       #{name => <<"temperature">>, oid => <<"1.3.6.1.4.1.99999.1.0">>},
                                                       #{name => <<"alarm">>, oid => <<"1.3.6.1.4.1.99999.5.0">>}],
                                        trap_rules => Rules}),
    s2i_trap_match:compile(Rs).

trap(TrapOid, Vbs) -> #{trap_oid => TrapOid, varbinds => Vbs}.

varbind_match_needs_no_rule_test() ->
    %% RFC 2863 linkDown carries ifOperStatus.<i>
    T = trap(?LINK_DOWN, [{?IF_INDEX(5), {integer, 5}}, {?ADMIN(5), {integer, 1}}, {?OPER(5), {integer, 2}}]),
    ?assertEqual({[#{oid => ?OPER(5), value => {integer, 2}, source => varbind}], []},
                 s2i_trap_match:match(T, [], lookup())).

unmatched_trap_test() ->
    ?assertEqual({[], []}, s2i_trap_match:match(trap(?COLD_START, [{?OPER(9), {integer, 2}}]), [], lookup())).

rule_with_instance_from_value_test() ->
    Rs = rules([#{name => <<"down">>, trap_oid => <<"1.3.6.1.6.3.1.1.5.3">>, datapoint => <<"if{slot}/oper">>,
                  instance => #{oid => <<"1.3.6.1.2.1.2.2.1.1">>, from => value}, set => 2}]),
    %% SNMPv1 linkDown only carries ifIndex.<i> = i
    {[A], []} = s2i_trap_match:match(trap(?LINK_DOWN, [{?IF_INDEX(6), {integer, 6}}]), Rs, lookup()),
    ?assertEqual(#{oid => ?OPER(6), value => {integer, 2}, source => <<"down">>}, A),
    %% other trap OID: no match
    ?assertEqual({[], []}, s2i_trap_match:match(trap(?COLD_START, [{?IF_INDEX(6), {integer, 6}}]), Rs, lookup())),
    %% instance that is not configured / resolved: a miss, never a guess
    ?assertEqual({[], [{<<"down">>, no_datapoint}]},
                 s2i_trap_match:match(trap(?LINK_DOWN, [{?IF_INDEX(7), {integer, 7}}]), Rs, lookup())),
    ?assertEqual({[], [{<<"down">>, no_instance}]},
                 s2i_trap_match:match(trap(?LINK_DOWN, []), Rs, lookup())).

rule_with_instance_from_suffix_test() ->
    Rs = rules([#{name => <<"down">>, trap_oid => <<"1.3.6.1.6.3.1.1.5.3">>, datapoint => <<"if{slot}/oper">>,
                  instance => #{oid => <<"1.3.6.1.2.1.2.2.1.7">>}, set => 2}]),
    {[#{oid := ?OPER(5)}], []} =
        s2i_trap_match:match(trap(?LINK_DOWN, [{?ADMIN(5), {integer, 1}}]), Rs, lookup()).

rules_come_after_varbind_match_test() ->
    Rs = rules([#{name => <<"down">>, trap_oid => <<"1.3.6.1.6.3.1.1.5.3">>, datapoint => <<"if{slot}/oper">>,
                  instance => #{oid => <<"1.3.6.1.2.1.2.2.1.8">>}, set => 7}]),
    {[#{source := varbind, value := {integer, 2}}, #{source := <<"down">>, value := {integer, 7}}], []} =
        s2i_trap_match:match(trap(?LINK_DOWN, [{?OPER(5), {integer, 2}}]), Rs, lookup()).

conditions_test() ->
    Rule = fun(Op, V) ->
                   rules([#{name => <<"a">>, trap_oid => <<"1.3.6.1.4.1.99999.0.1">>, datapoint => <<"alarm">>,
                            conditions => [#{oid => <<"1.3.6.1.4.1.99999.9">>, op => Op, value => V}],
                            set => 1}])
           end,
    Match = fun(Rs, Vbs) -> length(element(1, s2i_trap_match:match(trap(?ENT ++ [0, 1], Vbs), Rs, lookup()))) end,
    Sev = fun(V) -> [{?ENT ++ [9, 1], V}] end,
    %% a varbind below the condition OID (table column) with an equal value
    ?assertEqual(1, Match(Rule(eq, 3), Sev({integer, 3}))),
    ?assertEqual(1, Match(Rule(eq, 3), Sev({gauge32, 3}))),
    ?assertEqual(0, Match(Rule(eq, 3), Sev({integer, 4}))),
    ?assertEqual(0, Match(Rule(eq, 3), Sev({octet_string, <<"3">>}))),
    ?assertEqual(1, Match(Rule(eq, <<"major">>), Sev({octet_string, <<"major">>}))),
    ?assertEqual(1, Match(Rule(eq, <<"1.3.6.1">>), Sev({oid, [1, 3, 6, 1]}))),
    ?assertEqual(1, Match(Rule(ne, 3), Sev({integer, 4}))),
    ?assertEqual(0, Match(Rule(ne, 3), Sev({integer, 3}))),
    %% a missing varbind fails the condition, whatever the operator
    ?assertEqual(0, Match(Rule(eq, 3), [])),
    ?assertEqual(0, Match(Rule(ne, 3), [])).

take_auto_reset_and_confirm_test() ->
    Rs = rules([#{name => <<"temp">>, trap_oid => <<"1.3.6.1.4.1.99999.0.2">>, datapoint => <<"temperature">>,
                  take => <<"1.3.6.1.4.1.99999.3">>, confirm_get_after => 200},
                #{name => <<"alarm">>, trap_oid => <<"1.3.6.1.4.1.99999.0.2">>, datapoint => <<"alarm">>,
                  set => <<"on">>, auto_reset => #{delay => 1000, value => <<"off">>}}]),
    {[Temp, Alarm], []} =
        s2i_trap_match:match(trap(?ENT ++ [0, 2], [{?ENT ++ [3, 0], {integer, 333}}]), Rs, lookup()),
    ?assertEqual(#{oid => ?TEMP, value => {integer, 333}, source => <<"temp">>, confirm_get_after => 200}, Temp),
    ?assertEqual(#{oid => ?ALARM, value => {octet_string, <<"on">>}, source => <<"alarm">>,
                   auto_reset => #{delay => 1000, value => {octet_string, <<"off">>}}}, Alarm),
    ?assertEqual({[], [{<<"temp">>, no_value}]},
                 s2i_trap_match:match(trap(?ENT ++ [0, 2], []), tl(lists:reverse(Rs)), lookup())).

%%% ordering rule

poll_applies_test() ->
    ?assert(s2i_trap_match:poll_applies(?OPER(5), 100, #{})),
    ?assert(s2i_trap_match:poll_applies(?OPER(5), 100, #{?OPER(6) => 200})),
    %% a request sent before (or at) the last trap must not overwrite it
    ?assertNot(s2i_trap_match:poll_applies(?OPER(5), 100, #{?OPER(5) => 200})),
    ?assertNot(s2i_trap_match:poll_applies(?OPER(5), 200, #{?OPER(5) => 200})),
    ?assert(s2i_trap_match:poll_applies(?OPER(5), 201, #{?OPER(5) => 200})).
