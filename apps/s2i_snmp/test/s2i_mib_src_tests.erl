-module(s2i_mib_src_tests).
-include_lib("eunit/include/eunit.hrl").

-define(A, <<"-- leading comment\n"
             "A-MIB DEFINITIONS ::= BEGIN\n"
             "IMPORTS\n"
             "    MODULE-IDENTITY, OBJECT-TYPE FROM SNMPv2-SMI  -- x FROM FAKE-MIB\n"
             "    DisplayString FROM SNMPv2-TC\n"
             "    ifIndex FROM IF-MIB;\n"
             "a OBJECT-TYPE DESCRIPTION \"text with FROM X-MIB; and END\" ::= { b 1 }\n"
             "END\n">>).
-define(B, <<"B-MIB DEFINITIONS ::= BEGIN\n"
             "IMPORTS a FROM A-MIB;\n"
             "END\n">>).

split_single_test() ->
    {ok, [M]} = s2i_mib_src:split(?A),
    ?assertMatch(#{name := <<"A-MIB">>, source := ?A}, M),
    ?assertEqual([<<"IF-MIB">>, <<"SNMPv2-SMI">>, <<"SNMPv2-TC">>], maps:get(imports, M)).

split_bundle_test() ->
    {ok, [A, B]} = s2i_mib_src:split(<<?A/binary, "\n", ?B/binary>>),
    ?assertEqual(<<"A-MIB">>, maps:get(name, A)),
    ?assertEqual(<<"B-MIB">>, maps:get(name, B)),
    ?assertEqual(<<?A/binary, "\n">>, maps:get(source, A)),
    ?assertEqual(?B, maps:get(source, B)),
    ?assertEqual([<<"A-MIB">>], maps:get(imports, B)).

no_imports_test() ->
    {ok, [M]} = s2i_mib_src:split(<<"X DEFINITIONS ::= BEGIN x OBJECT IDENTIFIER ::= { iso 9 } END">>),
    ?assertEqual([], maps:get(imports, M)).

module_oid_and_tags_test() ->
    {ok, [M]} = s2i_mib_src:split(<<"X-MIB { iso 3 } DEFINITIONS IMPLICIT TAGS ::= BEGIN END">>),
    ?assertEqual(<<"X-MIB">>, maps:get(name, M)).

errors_test() ->
    ?assertEqual({error, no_module}, s2i_mib_src:split(<<"just text">>)),
    ?assertEqual({error, no_module},
                 s2i_mib_src:split(<<"-- X-MIB DEFINITIONS ::= BEGIN\nEND\n">>)),
    ?assertEqual({error, {no_end, <<"X-MIB">>}},
                 s2i_mib_src:split(<<"X-MIB DEFINITIONS ::= BEGIN\n x \"END\" -- END\n">>)),
    ?assertEqual({error, {no_end, <<"X-MIB">>}},
                 s2i_mib_src:split(<<"X-MIB DEFINITIONS ::= BEGIN\n x ::= { y-END 1 }\n">>)).

comment_ends_at_next_dashes_test() ->
    {ok, [M]} = s2i_mib_src:split(<<"X DEFINITIONS ::= BEGIN IMPORTS -- c -- a FROM Y-MIB; END">>),
    ?assertEqual([<<"Y-MIB">>], maps:get(imports, M)).

valid_name_test() ->
    ?assert(s2i_mib_src:valid_name(<<"IF-MIB">>)),
    ?assertNot(s2i_mib_src:valid_name(<<"../x">>)),
    ?assertNot(s2i_mib_src:valid_name(<<"1X">>)),
    ?assertNot(s2i_mib_src:valid_name(<<>>)),
    ?assertNot(s2i_mib_src:valid_name(x)).

known(N) -> lists:member(N, [<<"SNMPv2-SMI">>, <<"SNMPv2-TC">>]).

order_test() ->
    Mods = #{<<"C">> => [<<"B">>, <<"SNMPv2-SMI">>], <<"B">> => [<<"A">>], <<"A">> => [<<"SNMPv2-TC">>],
             <<"Z">> => []},
    ?assertEqual({[<<"A">>, <<"B">>, <<"C">>, <<"Z">>], #{}}, s2i_mib_src:order(Mods, fun known/1)).

order_missing_and_blocked_test() ->
    Mods = #{<<"A">> => [<<"NOPE">>, <<"SNMPv2-SMI">>], <<"B">> => [<<"A">>], <<"C">> => [<<"B">>],
             <<"D">> => []},
    ?assertEqual({[<<"D">>], #{<<"A">> => {missing, [<<"NOPE">>]},
                               <<"B">> => {dependency, [<<"A">>]},
                               <<"C">> => {dependency, [<<"B">>]}}},
                 s2i_mib_src:order(Mods, fun known/1)).

order_cycle_test() ->
    Mods = #{<<"A">> => [<<"B">>], <<"B">> => [<<"A">>], <<"C">> => [<<"C">>]},
    ?assertEqual({[<<"C">>], #{<<"A">> => {dependency, [<<"B">>]}, <<"B">> => {dependency, [<<"A">>]}}},
                 s2i_mib_src:order(Mods, fun known/1)).

cache_key_test() ->
    K = s2i_mib_src:cache_key(<<"v1">>, <<"src">>, [{<<"A">>, <<"k1">>}, {<<"B">>, <<"k2">>}]),
    ?assertEqual(K, s2i_mib_src:cache_key(<<"v1">>, <<"src">>, [{<<"B">>, <<"k2">>}, {<<"A">>, <<"k1">>}])),
    ?assertNotEqual(K, s2i_mib_src:cache_key(<<"v2">>, <<"src">>, [{<<"A">>, <<"k1">>}, {<<"B">>, <<"k2">>}])),
    ?assertNotEqual(K, s2i_mib_src:cache_key(<<"v1">>, <<"src">>, [{<<"A">>, <<"k3">>}, {<<"B">>, <<"k2">>}])),
    ?assertEqual(64, byte_size(K)).
