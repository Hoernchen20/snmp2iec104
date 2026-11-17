-module(s2i_web_ws_proto_tests).
-include_lib("eunit/include/eunit.hrl").

-define(P, s2i_web_ws_proto).

%%% topics

topic_test() ->
    ?assertEqual({ok, {device_values, <<"sw1">>}}, ?P:topic(<<"values:device:sw1">>)),
    ?assertEqual({ok, {server_values, <<"scada">>}}, ?P:topic(<<"values:server:scada">>)),
    ?assertEqual({ok, {trace, <<"sw1">>}}, ?P:topic(<<"snmp:trace:sw1">>)),
    ?assertEqual({ok, {iec, <<"scada">>}}, ?P:topic(<<"iec:scada">>)),
    ?assertEqual({ok, {traps, undefined}}, ?P:topic(<<"traps">>)),
    ?assertEqual({ok, {log, undefined}}, ?P:topic(<<"log">>)),
    [?assertEqual(error, ?P:topic(T))
     || T <- [<<"values:device:">>, <<"iec:">>, <<"values">>, <<"foo">>, <<"traps:x">>,
              <<"values:device:a\nb">>, <<"iec:", (binary:copy(<<"x">>, 200))/binary>>, 42]].

%%% client messages

decode_test() ->
    ?assertEqual({subscribe, <<"traps">>, #{}},
                 ?P:decode(<<"{\"op\":\"subscribe\",\"topic\":\"traps\"}">>)),
    ?assertEqual({subscribe, <<"log">>, #{level => warning}},
                 ?P:decode(<<"{\"op\":\"subscribe\",\"topic\":\"log\",\"level\":\"warning\"}">>)),
    ?assertEqual({error, invalid_level},
                 ?P:decode(<<"{\"op\":\"subscribe\",\"topic\":\"log\",\"level\":\"loud\"}">>)),
    ?assertEqual({unsubscribe, <<"iec:s1">>},
                 ?P:decode(<<"{\"op\":\"unsubscribe\",\"topic\":\"iec:s1\"}">>)),
    ?assertEqual(ping, ?P:decode(<<"{\"op\":\"ping\"}">>)),
    ?assertEqual({error, invalid_topic}, ?P:decode(<<"{\"op\":\"subscribe\",\"topic\":\"nope\"}">>)),
    ?assertEqual({error, invalid_topic}, ?P:decode(<<"{\"op\":\"subscribe\"}">>)),
    ?assertEqual({error, invalid_message}, ?P:decode(<<"{\"op\":\"dance\"}">>)),
    ?assertEqual({error, invalid_message}, ?P:decode(<<"[1]">>)),
    ?assertEqual({error, invalid_json}, ?P:decode(<<"{">>)).

log_level_test() ->
    ?assert(?P:log_passes(error, warning)),
    ?assert(?P:log_passes(warning, warning)),
    ?assertNot(?P:log_passes(info, warning)),
    ?assert(?P:log_passes(debug, undefined)).

%%% events

device_values_event_test() ->
    Ev = #{at => 1, source => poll,
           values => [#{oid => [1, 3, 6, 1, 2, 1, 2, 2, 1, 8, 3], value => {integer, 1},
                        datapoints => [<<"sw1/if{slot}">>],
                        writes => [{<<"s1">>, {1, 100}, #{type => m_sp_tb_1, value => true,
                                                         quality => [], ts => 5}},
                                   {<<"s2">>, {1, 7}, invalid}]},
                      #{oid => [1, 3, 6, 1, 2, 1, 1, 5, 0], value => {octet_string, <<"sw1">>},
                        datapoints => [], writes => []},
                      #{oid => [1, 3, 6, 1, 2, 1, 1, 6, 0], value => {octet_string, <<0, 255>>},
                        datapoints => [], writes => []},
                      #{oid => [1, 3], value => no_such_instance, datapoints => [], writes => []},
                      #{oid => [1, 4], value => {error, noSuchName}, datapoints => [], writes => []}]},
    ?assertEqual(
       #{at => 1, source => poll,
         values => [#{oid => <<"1.3.6.1.2.1.2.2.1.8.3">>, value => #{type => integer, value => 1},
                      datapoints => [<<"sw1/if{slot}">>],
                      writes => [#{server => <<"s1">>, coa => 1, ioa => 100,
                                   point => #{type => m_sp_tb_1, value => true, quality => [], ts => 5}},
                                 #{server => <<"s2">>, coa => 1, ioa => 7, invalid => true}]},
                    #{oid => <<"1.3.6.1.2.1.1.5.0">>, value => #{type => octet_string, value => <<"sw1">>,
                                                                 hex => <<"737731">>},
                      datapoints => [], writes => []},
                    #{oid => <<"1.3.6.1.2.1.1.6.0">>, value => #{type => octet_string, value => null,
                                                                 hex => <<"00ff">>},
                      datapoints => [], writes => []},
                    #{oid => <<"1.3">>, value => #{type => no_such_instance}, datapoints => [], writes => []},
                    #{oid => <<"1.4">>, value => #{type => error, value => noSuchName},
                      datapoints => [], writes => []}]},
       ?P:event(<<"values:device:sw1">>, Ev)),
    %% device down: only writes
    ?assertEqual(#{at => 2, source => down, writes => [#{server => <<"s1">>, coa => 1, ioa => 3, invalid => true}]},
                 ?P:event(<<"values:device:sw1">>, #{at => 2, source => down, writes => [{<<"s1">>, {1, 3}, invalid}]})).

server_values_event_test() ->
    ?assertEqual(#{at => 1, points => [#{coa => 1, ioa => 2, type => m_dp_tb_1, value => on,
                                         quality => [invalid], ts => 3}]},
                 ?P:event(<<"values:server:s1">>,
                          #{at => 1, points => [{{1, 2}, #{type => m_dp_tb_1, value => on,
                                                            quality => [invalid], ts => 3}}]})).

trace_event_test() ->
    Vb = {varbind, [1, 3, 6, 1, 2, 1, 1, 3, 0], 'TimeTicks', 42, 1},
    ?assertEqual(#{at => 1, dir => request, op => get, purpose => #{poll => <<"default">>},
                   oids => [<<"1.3.6.1.2.1.1.3.0">>], attempt => 0, req_id => 7},
                 ?P:event(<<"snmp:trace:d">>, #{at => 1, dir => request, op => get,
                                                 purpose => #{poll => <<"default">>},
                                                 oids => [[1, 3, 6, 1, 2, 1, 1, 3, 0]],
                                                 attempt => 0, req_id => 7})),
    ?assertEqual(#{at => 1, dir => response, req_id => 7, error_status => noError, error_index => 0,
                   late => false,
                   varbinds => [#{oid => <<"1.3.6.1.2.1.1.3.0">>, type => 'TimeTicks', value => 42}]},
                 ?P:event(<<"snmp:trace:d">>, #{at => 1, dir => response, req_id => 7, error_status => noError,
                                                 error_index => 0, late => false, varbinds => [Vb]})),
    %% arbitrary reasons become strings
    #{reason := R} = ?P:event(<<"snmp:trace:d">>, #{at => 1, dir => error, req_id => 7,
                                                     reason => {send_failed, 7, eaccess}}),
    ?assertEqual(<<"{send_failed,7,eaccess}">>, R).

trap_event_test() ->
    Ev = #{at => 1, device => <<"sw1">>, trap_oid => [1, 3, 6, 1, 6, 3, 1, 1, 5, 3],
           varbinds => [{[1, 3, 6, 1, 2, 1, 2, 2, 1, 1, 3], {integer, 3}}],
           matched => [varbind, <<"link">>], misses => [{<<"r2">>, no_instance}]},
    ?assertEqual(#{at => 1, device => <<"sw1">>, trap_oid => <<"1.3.6.1.6.3.1.1.5.3">>,
                   varbinds => [#{oid => <<"1.3.6.1.2.1.2.2.1.1.3">>, type => integer, value => 3}],
                   matched => [varbind, <<"link">>], misses => [#{rule => <<"r2">>, reason => no_instance}]},
                 ?P:event(<<"traps">>, Ev)),
    #{trap_oid := null, device := null, from := <<"10.0.0.1:162">>} =
        ?P:event(<<"traps">>, Ev#{trap_oid => undefined, device => null, from => <<"10.0.0.1:162">>}).

iec_and_log_events_test() ->
    Pid = list_to_pid("<0.42.0>"),
    ?assertEqual(#{at => 1, event => activated, conn => <<"<0.42.0>">>},
                 ?P:event(<<"iec:s1">>, #{at => 1, event => activated, conn => Pid})),
    ?assertEqual(#{at => 1, event => down, conn => <<"<0.42.0>">>, reason => closed},
                 ?P:event(<<"iec:s1">>, #{at => 1, event => down, conn => Pid, reason => closed})),
    Log = #{at => 1, level => info, msg => <<"hello">>, mfa => <<"m:f/1">>},
    ?assertEqual(Log, ?P:event(<<"log">>, Log)).

snapshot_test() ->
    Spec = #{type => m_me_nc_1, value => 1.5, quality => []},
    ?assertEqual([#{coa => 1, ioa => 2, type => m_me_nc_1, value => 1.5, quality => []}],
                 ?P:server_snapshot([{{1, 2}, Spec}])),
    ?assertEqual([#{server => <<"s1">>, coa => 1, ioa => 2, source => <<"sw1/temp">>,
                    point => Spec},
                  #{server => <<"s1">>, coa => 1, ioa => 3, source => <<"comm_status">>,
                    point => #{type => m_sp_na_1, value => false, quality => [invalid]}}],
                 ?P:device_snapshot([{<<"s1">>, {1, 2}, #{type => m_me_nc_1, source => {datapoint, <<"sw1/temp">>}}, Spec},
                                     {<<"s1">>, {1, 3}, #{type => m_sp_na_1, source => {comm_status, <<"sw1">>}},
                                      #{type => m_sp_na_1, value => false, quality => [invalid]}}])).

%%% rate limit

limit_test() ->
    L0 = ?P:limit_new(3),
    {ok, L1} = ?P:limit(1000, L0),
    {ok, L2} = ?P:limit(1100, L1),
    {ok, L3} = ?P:limit(1999, L2),
    {drop, L4} = ?P:limit(1999, L3),
    {drop, L5} = ?P:limit(1999, L4),
    ?assertEqual(2, ?P:dropped(L5)),
    %% next window
    {ok, L6} = ?P:limit(2000, L5),
    ?assertEqual(2, ?P:dropped(L6)),            % kept until reported
    {N, L7} = ?P:take_dropped(L6),
    ?assertEqual(2, N),
    ?assertEqual(0, ?P:dropped(L7)).

%%% origin (cross-site WebSocket hijacking)

origin_test() ->
    ?assert(?P:origin_ok(undefined, <<"gw.local">>, [])),          % not a browser
    ?assert(?P:origin_ok(<<"http://gw.local:8080">>, <<"gw.local">>, [])),
    ?assert(?P:origin_ok(<<"https://GW.local">>, <<"gw.local">>, [])),
    ?assertNot(?P:origin_ok(<<"https://evil.example">>, <<"gw.local">>, [])),
    ?assertNot(?P:origin_ok(<<"null">>, <<"gw.local">>, [])),
    ?assertNot(?P:origin_ok(<<"garbage">>, <<"gw.local">>, [])),
    %% explicitly allowed (e.g. the Vite dev server)
    ?assert(?P:origin_ok(<<"http://localhost:5173">>, <<"127.0.0.1">>, [<<"http://localhost:5173">>])),
    ?assertNot(?P:origin_ok(<<"http://localhost:5174">>, <<"127.0.0.1">>, [<<"http://localhost:5173">>])).
