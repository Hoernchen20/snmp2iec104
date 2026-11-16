-module(s2i_validate_tests).

-include_lib("eunit/include/eunit.hrl").

%%% A small but complete configuration: two servers, one profile, two devices.

server(Name, Port, Coas) ->
    #{name => Name, transport => #{kind => tcp, port => Port}, common_addresses => Coas}.

profile() ->
    #{name => <<"switch24">>,
      ioa_stride => 10,
      poll_groups => #{<<"status">> => 30000},
      resolvers => #{<<"if_name">> => #{column => <<"1.3.6.1.2.1.31.1.1.1.1">>}},
      datapoints =>
          [#{name => <<"if{slot}/operStatus">>,
             oid => <<"1.3.6.1.2.1.2.2.1.8.{index}">>,
             scope => instance, poll_group => <<"status">>,
             mappings => [#{ioa_offset => 1, type => m_sp_tb_1,
                            transform => #{kind => enum, map => #{<<"1">> => true,
                                                                  <<"2">> => false}}},
                          #{target => <<"counters">>, ioa_offset => 2, type => m_me_nc_1,
                            transform => #{kind => linear}}]}]}.

device(Name, Server) ->
    #{name => Name, host => <<"10.0.0.10">>,
      snmp => #{version => v2c, community => <<"public">>},
      profile => <<"switch24">>, ioa_base => 10000,
      instances => [#{slot => 1, key => #{resolver => <<"if_name">>,
                                          value => <<"Gi1/0/1">>}}],
      targets => #{<<"default">> => [#{server => Server, coa => 1}]}}.

config() ->
    #{servers => #{<<"scada1">> => server(<<"scada1">>, 2404, [1]),
                   <<"scada2">> => server(<<"scada2">>, 2405, [1, 2])},
      profiles => #{<<"switch24">> => profile()},
      devices => #{<<"sw-a">> => device(<<"sw-a">>, <<"scada1">>),
                   <<"sw-c">> => device(<<"sw-c">>, <<"scada2">>)}}.

errors(Config) ->
    {error, Errors} = s2i_validate:config(Config),
    lists:sort([{P, C} || #{path := P, error := C} <- Errors]).

has_error(Path, Code, Config) ->
    lists:member({Path, Code}, errors(Config)).

update_device(Name, Fun, C = #{devices := Ds}) ->
    C#{devices := Ds#{Name := Fun(maps:get(Name, Ds))}}.

%%% ---------------------------------------------------------------------------

valid_config_is_returned_normalised_test() ->
    {ok, #{devices := #{<<"sw-a">> := #{port := 161}},
           servers := #{<<"scada1">> := #{params := #{k := 12}}}}} =
        s2i_validate:config(config()).

empty_config_is_valid_test() ->
    ?assertMatch({ok, #{servers := #{}, devices := #{}, profiles := #{}}},
                 s2i_validate:config(#{})),
    ?assertMatch({ok, _}, s2i_validate:config(s2i_validate:empty())).

unknown_section_test() ->
    ?assert(has_error([users], unknown_field, (config())#{users => #{}})).

entity_errors_are_prefixed_with_section_and_name_test() ->
    C = update_device(<<"sw-a">>, fun(D) -> D#{port => 0} end, config()),
    ?assertEqual([{[devices, <<"sw-a">>, port], out_of_range}], errors(C)).

key_must_match_entity_name_test() ->
    C = (config())#{servers => #{<<"other">> => server(<<"scada1">>, 2404, [1])}},
    ?assert(has_error([servers, <<"other">>, name], name_mismatch, C)).

unknown_profile_test() ->
    C = update_device(<<"sw-a">>, fun(D) -> D#{profile => <<"nope">>} end, config()),
    ?assertEqual([{[devices, <<"sw-a">>, profile], unknown_profile}], errors(C)).

unknown_server_in_target_test() ->
    C = update_device(<<"sw-a">>, fun(D) -> D#{targets => #{<<"default">> =>
                                        [#{server => <<"ghost">>, coa => 1}]}} end, config()),
    ?assert(has_error([devices, <<"sw-a">>, targets, <<"default">>, 0, server],
                      unknown_server, C)).

coa_not_served_by_server_test() ->
    C = update_device(<<"sw-a">>, fun(D) -> D#{targets => #{<<"default">> =>
                                        [#{server => <<"scada1">>, coa => 2}]}} end, config()),
    ?assert(has_error([devices, <<"sw-a">>, targets, <<"default">>, 0, coa], unknown_coa, C)).

unknown_target_label_test() ->
    C = update_device(<<"sw-a">>,
                      fun(D) -> D#{targets => #{<<"typo">> =>
                                                    [#{server => <<"scada1">>, coa => 1}]}} end,
                      config()),
    ?assert(has_error([devices, <<"sw-a">>, targets, <<"typo">>], unknown_target_label, C)).

unbound_label_is_allowed_test() ->
    %% sw-a binds only "default"; the profile also uses "counters": those mappings
    %% are simply not produced for this device.
    ?assertMatch({ok, _}, s2i_validate:config(config())).

unknown_resolver_test() ->
    C = update_device(<<"sw-a">>,
                      fun(D) -> D#{instances => [#{slot => 1, key => #{resolver => <<"r">>,
                                                                       value => <<"x">>}}]} end,
                      config()),
    ?assert(has_error([devices, <<"sw-a">>, instances, 0, key, resolver], unknown_resolver, C)).

comm_status_test() ->
    Cs = fun(M) -> update_device(<<"sw-a">>, fun(D) -> D#{comm_status => M} end, config()) end,
    ?assertMatch({ok, _}, s2i_validate:config(Cs(#{server => <<"scada1">>, coa => 1, ioa => 9}))),
    ?assert(has_error([devices, <<"sw-a">>, comm_status, server], unknown_server,
                      Cs(#{server => <<"ghost">>, coa => 1, ioa => 9}))),
    ?assert(has_error([devices, <<"sw-a">>, comm_status, coa], unknown_coa,
                      Cs(#{server => <<"scada1">>, coa => 5, ioa => 9}))).

ioa_must_fit_server_ioa_size_test() ->
    C0 = config(),
    S1 = (server(<<"scada1">>, 2404, [1]))#{params => #{ioa_size => 1}},
    C = (C0#{servers := (maps:get(servers, C0))#{<<"scada1">> := S1}}),
    C2 = update_device(<<"sw-a">>, fun(D) -> D#{ioa_base => 0, comm_status =>
                                                   #{server => <<"scada1">>, coa => 1,
                                                     ioa => 300}} end, C),
    ?assert(has_error([devices, <<"sw-a">>, comm_status, ioa], out_of_range, C2)).

port_conflict_test() ->
    C0 = config(),
    Servers = (maps:get(servers, C0))#{<<"scada2">> := server(<<"scada2">>, 2404, [1, 2])},
    ?assertEqual([{[servers, <<"scada2">>, transport, port], port_conflict}],
                 errors(C0#{servers := Servers})).

same_port_on_different_ips_is_fine_test() ->
    C0 = config(),
    S = fun(N, Ip) -> (server(N, 2404, [1, 2]))#{transport => #{kind => tcp, port => 2404,
                                                                 ip => Ip}} end,
    Servers = #{<<"scada1">> => S(<<"scada1">>, <<"10.0.0.1">>),
                <<"scada2">> => S(<<"scada2">>, <<"10.0.0.2">>)},
    ?assertMatch({ok, _}, s2i_validate:config(C0#{servers := Servers})),
    Wild = Servers#{<<"scada2">> := S(<<"scada2">>, <<"0.0.0.0">>)},
    ?assert(has_error([servers, <<"scada2">>, transport, port], port_conflict,
                      C0#{servers := Wild})).

reference_checks_are_skipped_for_broken_entities_test() ->
    %% a device with a schema error must not additionally produce noise
    C = update_device(<<"sw-a">>, fun(D) -> D#{profile => 42} end, config()),
    ?assertEqual([{[devices, <<"sw-a">>, profile], invalid_name}], errors(C)).
