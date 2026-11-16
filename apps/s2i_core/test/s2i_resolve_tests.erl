-module(s2i_resolve_tests).
-include_lib("eunit/include/eunit.hrl").

-define(COL, [1, 3, 6, 1, 2, 1, 31, 1, 1, 1, 1]).   %% ifName

build_maps_values_to_indexes_test() ->
    Rows = [{?COL ++ [1], "Gi1/0/1"},                 %% snmpm: OCTET STRING as byte list
            {?COL ++ [2], <<"Gi1/0/2">>},
            {[1, 3, 6, 1, 2, 1, 2, 2, 1, 2, 5], "other column"},
            {?COL ++ [7, 1], "compound index"}],
    ?assertEqual({#{<<"Gi1/0/1">> => 1, <<"Gi1/0/2">> => 2}, []},
                 s2i_resolve:build(?COL, Rows)).

duplicate_values_are_ambiguous_test() ->
    %% never guess: both rows are dropped and reported
    Rows = [{?COL ++ [1], "uplink"}, {?COL ++ [2], "uplink"}, {?COL ++ [3], "Gi1/0/3"}],
    ?assertEqual({#{<<"Gi1/0/3">> => 3}, [<<"uplink">>]}, s2i_resolve:build(?COL, Rows)).

non_string_values_are_ignored_test() ->
    ?assertEqual({#{}, []}, s2i_resolve:build(?COL, [{?COL ++ [1], 42}, {?COL ++ [2], noSuchInstance}])).

index_of_instance_test() ->
    Resolved = #{<<"if_name">> => #{<<"Gi1/0/3">> => 10103}},
    ?assertEqual({ok, 10101}, s2i_resolve:index(#{slot => 1, index => 10101}, Resolved)),
    ?assertEqual({ok, 10103},
                 s2i_resolve:index(#{slot => 3, key => #{resolver => <<"if_name">>, value => <<"Gi1/0/3">>}},
                                   Resolved)),
    ?assertEqual(unresolved,
                 s2i_resolve:index(#{slot => 4, key => #{resolver => <<"if_name">>, value => <<"Gi1/0/4">>}},
                                   Resolved)),
    ?assertEqual(unresolved,
                 s2i_resolve:index(#{slot => 4, key => #{resolver => <<"if_descr">>, value => <<"x">>}},
                                   Resolved)).

keys_of_device_test() ->
    Device = #{instances => [#{slot => 1, index => 10101},
                             #{slot => 3, key => #{resolver => <<"if_name">>, value => <<"Gi1/0/3">>}},
                             #{slot => 4, key => #{resolver => <<"if_name">>, value => <<"Gi1/0/4">>}},
                             #{slot => 9, key => #{resolver => <<"sensor">>, value => <<"cpu">>}}]},
    ?assertEqual(#{<<"if_name">> => [<<"Gi1/0/3">>, <<"Gi1/0/4">>], <<"sensor">> => [<<"cpu">>]},
                 s2i_resolve:keys(Device)).

changed_keys_test() ->
    Keys = #{<<"if_name">> => [<<"a">>, <<"b">>, <<"c">>]},
    Old = #{<<"if_name">> => #{<<"a">> => 1, <<"b">> => 2, <<"x">> => 9}},
    New = #{<<"if_name">> => #{<<"a">> => 1, <<"b">> => 5, <<"c">> => 3, <<"x">> => 10}},
    %% only keys the device uses count; unrelated rows (x) do not
    ?assertEqual([{<<"if_name">>, <<"b">>}, {<<"if_name">>, <<"c">>}],
                 s2i_resolve:changed(Keys, Old, New)),
    ?assertEqual([], s2i_resolve:changed(Keys, Old, Old)),
    ?assertEqual([{<<"if_name">>, <<"a">>}, {<<"if_name">>, <<"b">>}],
                 s2i_resolve:changed(Keys, Old, #{})).

columns_of_the_resolvers_a_device_needs_test() ->
    Device = #{instances => [#{slot => 1, key => #{resolver => <<"if_name">>, value => <<"Gi1">>}},
                             #{slot => 2, index => 7}]},
    Profile = #{resolvers => #{<<"if_name">> => #{column => <<"1.3.6.1.2.1.31.1.1.1.1">>},
                               <<"unused">> => #{column => <<"1.3.6.1.2.1.2.2.1.2">>}}},
    ?assertEqual(#{<<"if_name">> => [1, 3, 6, 1, 2, 1, 31, 1, 1, 1, 1]},
                 s2i_resolve:columns(Device, Profile)),
    ?assertEqual(#{}, s2i_resolve:columns(#{instances => []}, Profile)).
