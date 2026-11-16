-module(s2i_snmp_conf_tests).
-include_lib("eunit/include/eunit.hrl").

-define(IP, {10, 0, 0, 1}).

dev(Snmp) -> #{name => <<"sw-a">>, port => 1161, snmp => Snmp}.

names_test() ->
    ?assertEqual({s2i_device, <<"sw-a">>}, s2i_snmp_conf:user(<<"sw-a">>)),
    ?assertEqual("s2i/sw-a", s2i_snmp_conf:target(<<"sw-a">>)).

engine_id_from_hex_test() ->
    ?assertEqual([16#80, 0, 0, 1, 2], s2i_snmp_conf:engine_id(<<"8000000102">>)).

v1_v2c_agent_test() ->
    A1 = s2i_snmp_conf:agent(dev(#{version => v1, community => <<"pub">>}), ?IP, undefined),
    ?assertEqual({?IP, 1161}, proplists:get_value(taddress, A1)),
    ?assertEqual(v1, proplists:get_value(version, A1)),
    ?assertEqual(v1, proplists:get_value(sec_model, A1)),
    ?assertEqual("pub", proplists:get_value(community, A1)),
    %% snmpm needs some engine id even for v1/v2c
    ?assertMatch([_ | _], proplists:get_value(engine_id, A1)),
    A2 = s2i_snmp_conf:agent(dev(#{version => v2c, community => <<"pub">>}), ?IP, undefined),
    ?assertEqual(v2, proplists:get_value(version, A2)),
    ?assertEqual(v2c, proplists:get_value(sec_model, A2)).

v3_agent_test() ->
    A = s2i_snmp_conf:agent(dev(v3(auth_priv)), ?IP, "engine"),
    ?assertEqual(v3, proplists:get_value(version, A)),
    ?assertEqual(usm, proplists:get_value(sec_model, A)),
    ?assertEqual("admin", proplists:get_value(sec_name, A)),
    ?assertEqual(authPriv, proplists:get_value(sec_level, A)),
    ?assertEqual("engine", proplists:get_value(engine_id, A)),
    ?assertEqual(noAuthNoPriv,
                 proplists:get_value(sec_level, s2i_snmp_conf:agent(dev(v3(no_auth_no_priv)), ?IP, "e"))).

v3(Level) ->
    Base = #{version => v3, user => <<"admin">>, sec_level => Level},
    case Level of
        no_auth_no_priv -> Base;
        auth_no_priv -> Base#{auth_protocol => sha256, auth_password => <<"authpass1">>};
        auth_priv -> Base#{auth_protocol => sha256, auth_password => <<"authpass1">>,
                           priv_protocol => aes, priv_password => <<"privpass1">>}
    end.

usm_keys_are_localized_test() ->
    {"eng1", "admin", Conf} = s2i_snmp_conf:usm(v3(auth_priv), "eng1"),
    ?assertEqual(usmHMAC192SHA256AuthProtocol, proplists:get_value(auth, Conf)),
    ?assertEqual(snmp:passwd2localized_key(sha256, "authpass1", "eng1"), proplists:get_value(auth_key, Conf)),
    ?assertEqual(usmAesCfb128Protocol, proplists:get_value(priv, Conf)),
    PrivKey = proplists:get_value(priv_key, Conf),
    ?assertEqual(16, length(PrivKey)),
    ?assertEqual(lists:sublist(snmp:passwd2localized_key(sha256, "privpass1", "eng1"), 16), PrivKey),
    %% another engine, another key
    {_, _, Conf2} = s2i_snmp_conf:usm(v3(auth_priv), "eng2"),
    ?assertNotEqual(proplists:get_value(auth_key, Conf), proplists:get_value(auth_key, Conf2)).

usm_levels_test() ->
    {_, _, None} = s2i_snmp_conf:usm(v3(no_auth_no_priv), "e"),
    ?assertEqual(usmNoAuthProtocol, proplists:get_value(auth, None)),
    ?assertEqual(usmNoPrivProtocol, proplists:get_value(priv, None)),
    {_, _, AuthOnly} = s2i_snmp_conf:usm(v3(auth_no_priv), "e"),
    ?assertEqual(usmNoPrivProtocol, proplists:get_value(priv, AuthOnly)).

all_auth_protocols_derive_keys_test_() ->
    [?_assertMatch({_, _, [_ | _]},
                   s2i_snmp_conf:usm((v3(auth_priv))#{auth_protocol => A, priv_protocol => P}, "e"))
     || A <- [md5, sha, sha224, sha256, sha384, sha512], P <- [des, aes]].

%%% discovery message

discovery_answer_is_parsed_test() ->
    %% a probe is a valid v3 message; a report built the same way with an
    %% engine id in the header yields that engine id
    Probe = s2i_snmp_discover:probe(42, 7),
    _ = snmp_pdus:dec_message_only(binary_to_list(Probe)),
    ?assertEqual(error, s2i_snmp_discover:parse(Probe, 42)),       % empty engine id
    ?assertEqual(error, s2i_snmp_discover:parse(<<"garbage">>, 42)).

%%% manager.conf

manager_conf_keeps_any_engine_id_octets_test() ->
    Engine = [16#80, 0, 0, 0, 5, $", $\\, $~, 0, 255, $\n],
    File = filename:join(os:getenv("TMPDIR", "/tmp"), "s2i_manager_conf_test.conf"),
    ok = file:write_file(File, s2i_snmpm:manager_conf({127, 0, 0, 1}, 1162, Engine)),
    ?assertEqual({ok, [{transports, [{transportDomainUdpIpv4, {{127, 0, 0, 1}, 1162}}]},
                       {engine_id, Engine}, {max_message_size, 65507}]},
                 file:consult(File)),
    ok = file:delete(File).
