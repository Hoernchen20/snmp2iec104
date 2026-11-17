-module(s2i_web_mib_tests).
-include_lib("eunit/include/eunit.hrl").

-define(COL, [1, 3, 6, 1, 2, 1, 2, 2, 1, 8]).

col() ->
    #{oid => ?COL, name => <<"ifOperStatus">>, module => <<"IF-MIB">>, kind => column,
      syntax => <<"INTEGER">>, base_type => <<"INTEGER">>, enums => [#{value => 1, name => <<"up">>}],
      access => <<"read-only">>, description => <<"The state">>}.

notif() ->
    #{oid => [1, 3, 6, 1, 6, 3, 1, 1, 5, 3], name => <<"linkDown">>, module => <<"IF-MIB">>,
      kind => notification, objects => [?COL, [9, 9]]}.

translate([9, 9]) -> error;
translate(Oid) -> {ok, col(), lists:nthtail(length(?COL), Oid)}.

lookup([1]) -> {ok, #{oid => [1], name => <<"iso">>, module => <<"SNMPv2-SMI">>, kind => node}};
lookup(?COL) -> {ok, col()};
lookup(_) -> error.

info_test() ->
    ?assertEqual(#{oid => <<"1.3.6.1.2.1.2.2.1.8.3">>, base_oid => <<"1.3.6.1.2.1.2.2.1.8">>, index => <<"3">>,
                   name => <<"ifOperStatus">>, module => <<"IF-MIB">>, kind => column,
                   syntax => <<"INTEGER">>, base_type => <<"INTEGER">>,
                   enums => [#{value => 1, name => <<"up">>}]},
                 s2i_web_mib:info(col(), [3])),
    ?assertMatch(#{index := <<>>}, s2i_web_mib:info(col(), [])).

detail_test() ->
    ?assertMatch(#{access := <<"read-only">>, description := <<"The state">>, index := <<>>},
                 s2i_web_mib:detail(col(), fun translate/1)),
    ?assertMatch(#{objects := [#{name := <<"ifOperStatus">>, index := <<>>}, #{oid := <<"9.9">>}]},
                 s2i_web_mib:detail(notif(), fun translate/1)),
    [_, Unknown] = maps:get(objects, s2i_web_mib:detail(notif(), fun translate/1)),
    ?assertEqual(#{oid => <<"9.9">>}, Unknown).

node_test() ->
    Children = [{?COL ++ [1], undefined, true}],
    N = s2i_web_mib:node(?COL, Children, fun lookup/1, fun translate/1),
    ?assertMatch(#{oid := <<"1.3.6.1.2.1.2.2.1.8">>, def := #{name := <<"ifOperStatus">>}}, N),
    [First | _] = Path = maps:get(path, N),
    ?assertEqual(9, length(Path)),
    ?assertEqual(#{oid => <<"1">>, name => <<"iso">>}, First),
    ?assertEqual(#{oid => <<"1.3">>, name => null}, lists:nth(2, Path)),
    ?assertEqual([#{oid => <<"1.3.6.1.2.1.2.2.1.8.1">>, arc => 1, has_children => true, name => null}],
                 maps:get(children, N)),
    ?assertMatch(#{def := null, path := []}, s2i_web_mib:node([7], [], fun lookup/1, fun translate/1)).

parse_oid_test() ->
    ?assertEqual({ok, [1]}, s2i_web_mib:parse_oid(<<"1">>)),
    ?assertEqual({ok, [1, 3, 6]}, s2i_web_mib:parse_oid(<<".1.3.6">>)),
    ?assertEqual(error, s2i_web_mib:parse_oid(<<"1..3">>)),
    ?assertEqual(error, s2i_web_mib:parse_oid(<<"ifIndex">>)),
    ?assertEqual(error, s2i_web_mib:parse_oid(<<>>)),
    ?assertEqual(error, s2i_web_mib:parse_oid(<<"1.4294967296">>)).
