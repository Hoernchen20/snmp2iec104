-module(s2i_web_json_tests).
-include_lib("eunit/include/eunit.hrl").

dec(T) -> json:decode(s2i_web_json:encode(T)).

canonical_terms_pass_through_test() ->
    T = #{name => <<"sw1">>, enabled => true, port => 161, list => [1, 2, 3], kind => tcp,
          desc => <<"Ümlaut"/utf8>>, n => null},
    ?assertEqual(#{<<"name">> => <<"sw1">>, <<"enabled">> => true, <<"port">> => 161,
                   <<"list">> => [1, 2, 3], <<"kind">> => <<"tcp">>, <<"desc">> => <<"Ümlaut"/utf8>>,
                   <<"n">> => null}, dec(T)).

oid_like_lists_stay_arrays_test() ->
    ?assertEqual([65, 66], dec([65, 66])).

unencodable_terms_become_strings_test() ->
    ?assertEqual(#{<<"error">> => <<"{host,nxdomain}">>}, dec(#{error => {host, nxdomain}})),
    ?assert(is_binary(dec(self()))),
    ?assertEqual(base64:encode(<<255, 0>>), dec(<<255, 0>>)),
    ?assertEqual(#{<<"{a,b}">> => 1}, dec(#{{a, b} => 1})).

varbind_test() ->
    V = fun(T, X) -> dec(s2i_web_json:varbind({varbind, [1, 3, 6, 1], T, X, 1})) end,
    ?assertEqual(#{<<"oid">> => <<"1.3.6.1">>, <<"type">> => <<"INTEGER">>, <<"value">> => 5},
                 V('INTEGER', 5)),
    ?assertMatch(#{<<"value">> := <<"eth0">>, <<"hex">> := <<"65746830">>}, V('OCTET STRING', "eth0")),
    ?assertMatch(#{<<"value">> := null, <<"hex">> := <<"00ff">>}, V('OCTET STRING', [0, 255])),
    ?assertMatch(#{<<"value">> := null, <<"hex">> := <<"0001">>}, V('OCTET STRING', [0, 1])),
    ?assertMatch(#{<<"value">> := <<"10.0.0.1">>}, V('IpAddress', [10, 0, 0, 1])),
    ?assertMatch(#{<<"value">> := <<"1.3.6.1.4.1.9">>}, V('OBJECT IDENTIFIER', [1, 3, 6, 1, 4, 1, 9])),
    ?assertMatch(#{<<"value">> := <<"noSuchObject">>}, V('NULL', noSuchObject)),
    ?assertMatch(#{<<"type">> := <<"Counter64">>, <<"value">> := 18446744073709551615},
                 V('Counter64', 18446744073709551615)).

parse_oid_test() ->
    ?assertEqual({ok, [1, 3, 6, 1, 2, 1, 1, 3, 0]}, s2i_web_json:parse_oid(<<"1.3.6.1.2.1.1.3.0">>)),
    ?assertEqual({ok, [1, 3, 6]}, s2i_web_json:parse_oid(<<".1.3.6">>)),
    ?assertEqual(error, s2i_web_json:parse_oid(<<"1">>)),
    ?assertEqual(error, s2i_web_json:parse_oid(<<"1.3.x">>)),
    ?assertEqual(error, s2i_web_json:parse_oid(<<"1..3">>)),
    ?assertEqual(error, s2i_web_json:parse_oid(<<"1.-3">>)),
    ?assertEqual(error, s2i_web_json:parse_oid(<<"1.4294967296">>)),
    ?assertEqual(error, s2i_web_json:parse_oid(<<>>)),
    ?assertEqual(error, s2i_web_json:parse_oid(13)).
