-module(s2i_poll_tests).
-include_lib("eunit/include/eunit.hrl").

%%% chunks

chunks_split_by_max_varbinds_test() ->
    ?assertEqual([[a, b], [c, d], [e]], s2i_poll:chunks([a, b, c, d, e], 2)),
    ?assertEqual([[a, b]], s2i_poll:chunks([a, b], 30)),
    ?assertEqual([], s2i_poll:chunks([], 3)).

%%% drift-free schedule

next_deadline_keeps_the_grid_test() ->
    %% on time: next slot, nothing missed
    ?assertEqual({2000, 0}, s2i_poll:next_deadline(1000, 1000, 1005)),
    %% the tick for 1000 runs at 4200: slots 2000..4000 are skipped
    ?assertEqual({5000, 3}, s2i_poll:next_deadline(1000, 1000, 4200)),
    %% exactly on a slot counts as passed
    ?assertEqual({4000, 2}, s2i_poll:next_deadline(1000, 1000, 3000)).

%%% reboot detection

first_uptime_is_no_reboot_test() ->
    ?assertEqual({ok, {500, 10}}, s2i_poll:uptime(undefined, {500, 10})).

lower_uptime_from_a_newer_request_is_a_reboot_test() ->
    ?assertEqual({rebooted, {20, 30}}, s2i_poll:uptime({500, 10}, {20, 30})),
    ?assertEqual({ok, {600, 30}}, s2i_poll:uptime({500, 10}, {600, 30})).

older_request_answering_late_is_ignored_test() ->
    %% a request sent before the stored sample: neither a reboot nor stored
    ?assertEqual({ok, {500, 10}}, s2i_poll:uptime({500, 10}, {400, 5})).

%%% varbind values (snmpm, no MIB knowledge) -> s2i_transform values

value_tags_test() ->
    ?assertEqual({integer, -3}, s2i_poll:value('INTEGER', -3)),
    ?assertEqual({integer, 4}, s2i_poll:value('Integer32', 4)),
    ?assertEqual({gauge32, 7}, s2i_poll:value('Unsigned32', 7)),
    ?assertEqual({gauge32, 7}, s2i_poll:value('Gauge32', 7)),
    ?assertEqual({counter32, 9}, s2i_poll:value('Counter32', 9)),
    ?assertEqual({counter64, 1 bsl 40}, s2i_poll:value('Counter64', 1 bsl 40)),
    ?assertEqual({timeticks, 100}, s2i_poll:value('TimeTicks', 100)),
    ?assertEqual({octet_string, <<"ge-0/0/1">>}, s2i_poll:value('OCTET STRING', "ge-0/0/1")),
    ?assertEqual({octet_string, <<1, 2>>}, s2i_poll:value('OCTET STRING', <<1, 2>>)),
    ?assertEqual({octet_string, <<10, 0, 0, 1>>}, s2i_poll:value('IpAddress', [10, 0, 0, 1])),
    ?assertEqual({oid, [1, 3, 6]}, s2i_poll:value('OBJECT IDENTIFIER', [1, 3, 6])),
    ?assertEqual(no_such_object, s2i_poll:value('NULL', noSuchObject)),
    ?assertEqual(no_such_instance, s2i_poll:value('NULL', noSuchInstance)),
    ?assertEqual(end_of_mib_view, s2i_poll:value('NULL', endOfMibView)),
    ?assertEqual({null, 'NULL'}, s2i_poll:value('NULL', 'NULL')),
    ?assertEqual({opaque, [1]}, s2i_poll:value('Opaque', [1])).

%%% device health

health_test() ->
    ?assertEqual(up, s2i_poll:health(0, 3)),
    ?assertEqual(degraded, s2i_poll:health(1, 3)),
    ?assertEqual(degraded, s2i_poll:health(2, 3)),
    ?assertEqual(down, s2i_poll:health(3, 3)),
    ?assertEqual(down, s2i_poll:health(1, 1)).
