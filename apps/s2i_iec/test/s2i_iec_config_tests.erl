-module(s2i_iec_config_tests).
-include_lib("eunit/include/eunit.hrl").

server(Extra) ->
    {ok, S} = s2i_schema:normalize(server, maps:merge(#{name => <<"scada1">>,
                                                        transport => #{kind => tcp},
                                                        common_addresses => [1, 2]}, Extra)),
    S.

tcp_defaults_test() ->
    ?assertEqual(
       #{transport => {tcp, [{ip, {0, 0, 0, 0}}, {port, 2404}]},
         common_addresses => [1, 2],
         params => #{k => 12, w => 8, t1 => 15000, t2 => 10000, t3 => 20000,
                     coa_size => 2, ioa_size => 3, cot_size => 2},
         redundancy => #{mode => connection, buffer => 1000},
         data_model => {s2i_iec_dm, #{server => <<"scada1">>}},
         callback => {s2i_iec_callback, #{server => <<"scada1">>}}},
       s2i_iec_config:server(server(#{}))).

ipv6_listener_test() ->
    #{transport := {tcp, [{ip, {0, 0, 0, 0, 0, 0, 0, 0}}, {port, 2405}]}} =
        s2i_iec_config:server(server(#{transport => #{kind => tcp, ip => <<"::">>, port => 2405}})).

tls_test() ->
    T = #{kind => tls, certfile => <<"/etc/s2i/cert.pem">>, keyfile => <<"/etc/s2i/key.pem">>,
          cacertfile => <<"/etc/s2i/ca.pem">>},
    #{transport := {tls, Opts}} = s2i_iec_config:server(server(#{transport => T})),
    ?assertEqual([{ip, {0, 0, 0, 0}}, {port, 19998}, {certfile, "/etc/s2i/cert.pem"},
                  {keyfile, "/etc/s2i/key.pem"}, {cacertfile, "/etc/s2i/ca.pem"}], Opts),
    %% verify => false opts out of mutual authentication (erl60870 default is verify_peer)
    #{transport := {tls, Opts2}} = s2i_iec_config:server(server(#{transport => T#{verify => false}})),
    ?assertEqual({verify, verify_none}, lists:last(Opts2)).

redundancy_groups_test() ->
    R = #{mode => multiple, buffer => 500,
          groups => [#{name => <<"main">>, match => [<<"10.0.0.0/24">>, <<"10.0.1.7/32">>]},
                     #{name => <<"backup">>, match => [<<"fd00::/64">>], buffer => 2000}]},
    #{redundancy := Red} = s2i_iec_config:server(server(#{redundancy => R})),
    ?assertEqual(#{mode => multiple, buffer => 500,
                   groups => [#{name => <<"main">>,
                                match => [{ip, {10, 0, 0, 0}, 24}, {ip, {10, 0, 1, 7}, 32}]},
                              #{name => <<"backup">>, match => [{ip, {16#fd00, 0, 0, 0, 0, 0, 0, 0}, 64}],
                                buffer => 2000}]},
                 Red).

background_scan_is_not_part_of_the_library_config_test() ->
    %% handled by s2i_iec_mgr; changing it must not restart the server
    ?assertEqual(s2i_iec_config:server(server(#{})),
                 s2i_iec_config:server(server(#{background_scan => 60000, description => <<"x">>}))).

seed_is_invalid_test_() ->
    [?_assertEqual(#{type => T, value => V, quality => [invalid]}, s2i_iec_config:seed(T))
     || {T, V} <- [{m_sp_na_1, false}, {m_sp_tb_1, false}, {m_dp_tb_1, 0}, {m_st_na_1, 0},
                   {m_me_na_1, 0}, {m_me_te_1, 0}, {m_me_nc_1, 0.0}, {m_me_tf_1, 0.0},
                   {m_it_na_1, 0}, {m_it_tb_1, 0}]].

name_test() ->
    ?assertEqual({s2i, <<"scada1">>}, s2i_iec_config:name(<<"scada1">>)).
