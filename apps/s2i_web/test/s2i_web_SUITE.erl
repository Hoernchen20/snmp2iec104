-module(s2i_web_SUITE).
-moduledoc """
REST API and WebSocket end to end (docs/DESIGN.md §9): the whole gateway
with an HTTP listener on a free port, driven with `httpc` and `gun` (WS). The cases share one
gateway and run in order; the first one completes the bootstrap admin's
forced password change.
""".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, suite/0, init_per_suite/1, end_per_suite/1]).
-export([bootstrap_admin_must_change_password/1,
         login_and_cookie_attributes/1,
         unauthenticated_requests_are_rejected/1,
         mutations_need_csrf_header/1,
         bad_requests/1,
         entity_crud/1,
         invalid_entity_reports_schema_errors/1,
         secrets_are_never_returned_in_plaintext/1,
         validate_activate_versions_restore/1,
         validate_reports_server_restarts/1,
         export_import_audit/1,
         viewer_is_read_only/1,
         user_admin_and_sessions/1,
         last_admin_cannot_be_removed/1,
         logout_ends_session/1,
         status_of_devices_and_servers/1,
         snmp_tools_through_device/1,
         mib_library/1,
         ws_upgrade_needs_session_and_origin/1,
         ws_protocol_errors_and_ping/1,
         ws_device_values_and_trace/1,
         ws_server_values_and_groups/1,
         ws_traps_with_history/1,
         ws_log_with_level/1,
         ws_closed_when_session_ends/1,
         static_ui_and_spa_fallback/1,
         idle_session_expires/1,
         openapi_is_public/1]).

-define(BOOT_PW, "bootstrap-password").
-define(ADMIN_PW, <<"admin-password-1">>).
-define(PROFILE, <<"sw">>).

suite() -> [{timetrap, {seconds, 60}}].

all() ->
    [bootstrap_admin_must_change_password,
     login_and_cookie_attributes,
     unauthenticated_requests_are_rejected,
     mutations_need_csrf_header,
     bad_requests,
     entity_crud,
     invalid_entity_reports_schema_errors,
     secrets_are_never_returned_in_plaintext,
     validate_activate_versions_restore,
     validate_reports_server_restarts,
     export_import_audit,
     viewer_is_read_only,
     user_admin_and_sessions,
     last_admin_cannot_be_removed,
     logout_ends_session,
     status_of_devices_and_servers,
     snmp_tools_through_device,
     mib_library,
     ws_upgrade_needs_session_and_origin,
     ws_protocol_errors_and_ping,
     ws_device_values_and_trace,
     ws_server_values_and_groups,
     ws_traps_with_history,
     ws_log_with_level,
     ws_closed_when_session_ends,
     static_ui_and_spa_fallback,
     idle_session_expires,
     openapi_is_public].

init_per_suite(Config) ->
    Dir = ?config(priv_dir, Config),
    ok = application:set_env(mnesia, dir, filename:join([Dir, "data", "mnesia"])),
    ok = application:load(s2i_core),
    ok = application:set_env(s2i_core, secret_key_file, filename:join([Dir, "etc", "secret.key"])),
    ok = application:set_env(s2i_core, password_iterations, 1000),
    ok = application:load(s2i_snmp),
    ok = application:set_env(s2i_snmp, dir, filename:join([Dir, "data", "snmp"])),
    ok = application:set_env(s2i_snmp, ip, "127.0.0.1"),
    ok = application:set_env(s2i_snmp, port, free_udp_port()),
    ok = application:load(s2i_web),
    ok = application:set_env(s2i_web, http, [{ip, "127.0.0.1"}, {port, 0}]),
    ok = application:set_env(s2i_web, admin_password, ?BOOT_PW),
    {ok, Started} = application:ensure_all_started(snmp2iec104),
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(gun),
    {ok, Agent} = s2i_fake_agent:start(),
    ok = s2i_fake_agent:set(Agent, [1, 3, 6, 1, 4, 1, 99999, 1, 0], {'INTEGER', 215}),
    ok = s2i_fake_agent:set(Agent, [1, 3, 6, 1, 4, 1, 99999, 2, 0], {'INTEGER', 1}),
    [{started, Started}, {agent, Agent}, {base, base_url()}, {iec_port, free_tcp_port()} | Config].

end_per_suite(Config) ->
    s2i_fake_agent:stop(?config(agent, Config)),
    [application:stop(App) || App <- lists:reverse(?config(started, Config))],
    %% unload: the env set here must not leak into later suites
    [application:unload(App) || App <- [s2i_core, s2i_snmp, s2i_web]],
    ok.

base_url() ->
    "http://127.0.0.1:" ++ integer_to_list(s2i_web_sup:port(http)) ++ "/api/v1/".

%%% ===========================================================================
%%% Cases
%%% ===========================================================================

bootstrap_admin_must_change_password(Config) ->
    {200, H, Me} = req(Config, post, "login", none, #{username => <<"admin">>, password => <<?BOOT_PW>>}),
    ?assertEqual(#{<<"name">> => <<"admin">>, <<"role">> => <<"admin">>, <<"must_change_password">> => true}, Me),
    S = cookie(H),
    {403, _, #{<<"error">> := <<"password_change_required">>}} = req(Config, get, "devices", S),
    {200, _, #{<<"must_change_password">> := true}} = req(Config, get, "me", S),
    {401, _, #{<<"error">> := <<"invalid_credentials">>}} =
        req(Config, post, "me/password", S, #{current_password => <<"wrong-password">>,
                                              new_password => ?ADMIN_PW}),
    {422, _, #{<<"errors">> := [#{<<"path">> := [<<"new_password">>], <<"error">> := <<"too_short">>}]}} =
        req(Config, post, "me/password", S, #{current_password => <<?BOOT_PW>>, new_password => <<"short">>}),
    {200, _, #{<<"must_change_password">> := false}} =
        req(Config, post, "me/password", S, #{current_password => <<?BOOT_PW>>, new_password => ?ADMIN_PW}),
    {200, _, []} = req(Config, get, "devices", S),
    %% the bootstrap password is gone
    {401, _, _} = req(Config, post, "login", none, #{username => <<"admin">>, password => <<?BOOT_PW>>}).

login_and_cookie_attributes(Config) ->
    {200, H, _} = req(Config, post, "login", none, #{username => <<"admin">>, password => ?ADMIN_PW}),
    SetCookie = string:lowercase(proplists:get_value("set-cookie", H)),
    ?assertNotEqual(nomatch, string:find(SetCookie, "httponly")),
    ?assertNotEqual(nomatch, string:find(SetCookie, "samesite=strict")),
    ?assertNotEqual(nomatch, string:find(SetCookie, "path=/")),
    %% 256-bit token, base64url without padding
    "s2i_session=" ++ Rest = proplists:get_value("set-cookie", H),
    [Token | _] = string:split(Rest, ";"),
    ?assertEqual(43, length(Token)),
    {401, _, #{<<"error">> := <<"invalid_credentials">>}} =
        req(Config, post, "login", none, #{username => <<"admin">>, password => <<"wrong-password">>}),
    {401, _, #{<<"error">> := <<"invalid_credentials">>}} =
        req(Config, post, "login", none, #{username => <<"nobody">>, password => ?ADMIN_PW}),
    {400, _, #{<<"error">> := <<"bad_request">>}} = req(Config, post, "login", none, #{username => <<"admin">>}).

unauthenticated_requests_are_rejected(Config) ->
    {401, _, #{<<"error">> := <<"unauthenticated">>}} = req(Config, get, "devices", none),
    {401, _, _} = req(Config, get, "config/staged", none),
    {401, _, _} = req(Config, get, "devices", "s2i_session=forged-token"),
    {401, _, _} = req(Config, put, "servers/x", none, #{}).

mutations_need_csrf_header(Config) ->
    S = admin(Config),
    {403, _, #{<<"error">> := <<"csrf">>}} =
        raw(Config, put, "servers/scada", [{"cookie", S}], json:encode(server(?config(iec_port, Config)))),
    {403, _, #{<<"error">> := <<"csrf">>}} =
        raw(Config, post, "login", [], json:encode(#{username => <<"admin">>, password => ?ADMIN_PW})),
    {404, _, _} = req(Config, get, "servers/scada", S).

bad_requests(Config) ->
    S = admin(Config),
    {404, _, #{<<"error">> := <<"not_found">>}} = req(Config, get, "nothing/here", S),
    {405, H, #{<<"error">> := <<"method_not_allowed">>}} = req(Config, post, "devices", S, #{}),
    ?assertEqual("GET", proplists:get_value("allow", H)),
    {400, _, #{<<"error">> := <<"invalid_json">>}} =
        raw(Config, put, "servers/scada", [{"cookie", S}, csrf()], <<"{not json">>),
    {400, _, _} = req(Config, put, "servers/scada", S, [1, 2]),
    {400, _, _} = req(Config, get, "config/audit?limit=abc", S),
    {400, _, _} = req(Config, get, "config/export?source=elsewhere", S),
    {404, _, _} = req(Config, get, "config/versions/abc", S),
    {413, _, #{<<"error">> := <<"payload_too_large">>}} =
        raw(Config, post, "config/import", [{"cookie", S}, csrf()],
            iolist_to_binary([<<"[">>, lists:join(<<",">>, lists:duplicate(4500000, <<"1">>)), <<"]">>])).

entity_crud(Config) ->
    S = admin(Config),
    {200, _, Created} = req(Config, put, "servers/scada", S, server(?config(iec_port, Config))),
    %% canonical form with defaults
    #{<<"name">> := <<"scada">>, <<"params">> := #{<<"k">> := 12}} = Created,
    {200, _, Created} = req(Config, get, "servers/scada", S),
    {200, _, [Created]} = req(Config, get, "servers", S),
    {422, _, #{<<"errors">> := [#{<<"error">> := <<"name_mismatch">>}]}} =
        req(Config, put, "servers/other", S, server(2405)),
    %% name in the body may be left out
    {200, _, #{<<"name">> := <<"tmp">>}} = req(Config, put, "servers/tmp", S, maps:remove(name, server(2406))),
    {204, _, _} = req(Config, delete, "servers/tmp", S),
    {404, _, _} = req(Config, delete, "servers/tmp", S),
    {404, _, _} = req(Config, get, "servers/tmp", S),
    {200, _, _} = req(Config, put, "profiles/sw", S, profile()).

invalid_entity_reports_schema_errors(Config) ->
    S = admin(Config),
    {422, _, #{<<"error">> := <<"invalid">>, <<"errors">> := Errors}} =
        req(Config, put, "servers/bad", S, #{transport => #{kind => tcp, port => 70000},
                                             common_addresses => [], color => blue}),
    Paths = lists:sort([{P, E} || #{<<"path">> := P, <<"error">> := E} <- Errors]),
    ?assertEqual(lists:sort([{[<<"color">>], <<"unknown_field">>},
                             {[<<"transport">>, <<"port">>], <<"out_of_range">>},
                             {[<<"common_addresses">>], <<"too_short">>}]), Paths),
    {404, _, _} = req(Config, get, "servers/bad", S).

secrets_are_never_returned_in_plaintext(Config) ->
    S = admin(Config),
    Port = s2i_fake_agent:port(?config(agent, Config)),
    {200, _, Dev} = req(Config, put, "devices/sw-a", S, device(Port)),
    #{<<"snmp">> := #{<<"community">> := <<"enc:v1:", _/binary>> = Envelope}} = Dev,
    {200, _, Body} = raw(Config, get, "devices/sw-a", [{"cookie", S}], <<>>),
    ?assertEqual(nomatch, binary:match(iolist_to_binary(json:encode(Body)), <<"public">>)),
    %% PUT of what GET returned keeps the secret as it is
    {200, _, #{<<"snmp">> := #{<<"community">> := Envelope}}} = req(Config, put, "devices/sw-a", S, Dev),
    %% export carries envelopes only
    {200, _, Export} = req(Config, get, "config/export", S),
    ?assertEqual(nomatch, binary:match(iolist_to_binary(json:encode(Export)), <<"public">>)).

validate_activate_versions_restore(Config) ->
    S = admin(Config),
    {200, _, #{<<"valid">> := true, <<"has_changes">> := true}} = req(Config, post, "config/validate", S),
    {200, _, #{<<"vsn">> := 1}} = req(Config, post, "config/activate", S, #{comment => <<"first">>}),
    {409, _, #{<<"error">> := <<"no_changes">>}} = req(Config, post, "config/activate", S),
    {200, _, #{<<"vsn">> := 1, <<"config">> := #{<<"servers">> := #{<<"scada">> := _}}}} =
        req(Config, get, "config/active", S),
    %% a broken reference cannot be activated
    {200, _, _} = req(Config, put, "devices/sw-b", S,
                      (device(1161))#{name => <<"sw-b">>, profile => <<"missing">>, ioa_base => 5000}),
    {200, _, #{<<"valid">> := false, <<"errors">> := [_ | _]}} = req(Config, post, "config/validate", S),
    {422, _, #{<<"errors">> := [_ | _]}} = req(Config, post, "config/activate", S),
    {422, _, _} = req(Config, post, "config/activate", S, #{comment => 42}),
    {200, _, #{<<"has_changes">> := true}} = req(Config, get, "config/staged", S),
    {204, _, _} = req(Config, post, "config/revert", S),
    {200, _, #{<<"has_changes">> := false}} = req(Config, get, "config/staged", S),
    %% second version, then restore the first
    {200, _, _} = req(Config, put, "servers/scada", S, (server(?config(iec_port, Config)))#{description => <<"v2">>}),
    {200, _, #{<<"vsn">> := 2}} = req(Config, post, "config/activate", S, #{comment => <<"second">>}),
    {200, _, [#{<<"vsn">> := 2, <<"author">> := <<"admin">>, <<"comment">> := <<"second">>},
              #{<<"vsn">> := 1}]} = req(Config, get, "config/versions", S),
    {200, _, #{<<"vsn">> := 1, <<"config">> := _}} = req(Config, get, "config/versions/1", S),
    {404, _, _} = req(Config, get, "config/versions/99", S),
    {404, _, _} = req(Config, post, "config/versions/99/restore", S),
    {204, _, _} = req(Config, post, "config/versions/1/restore", S),
    {200, _, Scada} = req(Config, get, "servers/scada", S),
    ?assertNot(is_map_key(<<"description">>, Scada)),
    {200, _, #{<<"vsn">> := 3}} = req(Config, post, "config/activate", S, #{comment => <<"rollback">>}).

validate_reports_server_restarts(Config) ->
    S = admin(Config),
    {200, _, #{<<"server_restarts">> := []}} = req(Config, post, "config/validate", S),
    {200, _, _} = req(Config, put, "servers/scada", S, (server(?config(iec_port, Config)))#{description => <<"text only">>}),
    {200, _, #{<<"server_restarts">> := []}} = req(Config, post, "config/validate", S),
    {200, _, _} = req(Config, put, "servers/scada", S, server(free_tcp_port())),
    {200, _, #{<<"server_restarts">> := [<<"scada">>]}} = req(Config, post, "config/validate", S),
    {204, _, _} = req(Config, post, "config/revert", S).

export_import_audit(Config) ->
    S = admin(Config),
    {200, _, Active} = req(Config, get, "config/export?source=active", S),
    {200, _, _} = req(Config, put, "servers/extra", S, (server(2410))#{name => <<"extra">>}),
    {204, _, _} = req(Config, post, "config/import", S, Active),
    {404, _, _} = req(Config, get, "servers/extra", S),
    {200, _, #{<<"has_changes">> := false}} = req(Config, get, "config/staged", S),
    {422, _, #{<<"errors">> := [_ | _]}} =
        req(Config, post, "config/import", S, #{servers => #{<<"x">> => #{}}, devices => #{}, profiles => #{}}),
    {200, _, Audit} = req(Config, get, "config/audit?limit=5", S),
    ?assertEqual(5, length(Audit)),
    [#{<<"action">> := <<"import">>, <<"actor">> := <<"admin">>} | _] = Audit.

viewer_is_read_only(Config) ->
    A = admin(Config),
    {200, _, #{<<"role">> := <<"viewer">>, <<"must_change_password">> := false}} =
        req(Config, put, "users/view", A, #{role => viewer, password => <<"viewer-password">>,
                                            must_change_password => false}),
    V = login(Config, <<"view">>, <<"viewer-password">>),
    {200, _, [_ | _]} = req(Config, get, "servers", V),
    {200, _, _} = req(Config, get, "config/staged", V),
    {200, _, _} = req(Config, post, "config/validate", V),
    {200, _, _} = req(Config, get, "status", V),
    {403, _, #{<<"error">> := <<"forbidden">>}} = req(Config, put, "servers/v", V, server(2420)),
    {403, _, _} = req(Config, delete, "servers/scada", V),
    {403, _, _} = req(Config, post, "config/activate", V),
    {403, _, _} = req(Config, post, "config/revert", V),
    {403, _, _} = req(Config, post, "config/import", V, #{}),
    {403, _, _} = req(Config, post, "config/versions/1/restore", V),
    {403, _, _} = req(Config, get, "users", V),
    {403, _, _} = req(Config, put, "users/view", V, #{role => admin}).

user_admin_and_sessions(Config) ->
    A = admin(Config),
    {200, _, #{<<"must_change_password">> := true}} =
        req(Config, put, "users/bob", A, #{role => viewer, password => <<"bob-password">>}),
    {200, _, Users} = req(Config, get, "users", A),
    ?assertEqual([<<"admin">>, <<"bob">>, <<"view">>], [N || #{<<"name">> := N} <- Users]),
    [?assertNot(is_map_key(<<"password">>, U)) || U <- Users],
    B = login(Config, <<"bob">>, <<"bob-password">>),
    {200, _, _} = req(Config, post, "me/password", B, #{current_password => <<"bob-password">>,
                                                        new_password => <<"bobs-own-password">>}),
    {200, _, _} = req(Config, get, "devices", B),
    %% role change applies to the running session at once
    {200, _, #{<<"role">> := <<"admin">>}} = req(Config, put, "users/bob", A, #{role => admin}),
    {200, _, [_ | _]} = req(Config, get, "users", B),
    {200, _, _} = req(Config, put, "users/bob", A, #{role => viewer}),
    %% a password reset by the admin ends bob's sessions
    {200, _, _} = req(Config, put, "users/bob", A, #{password => <<"reset-password">>}),
    {401, _, _} = req(Config, get, "devices", B),
    B2 = login(Config, <<"bob">>, <<"reset-password">>),
    {403, _, #{<<"error">> := <<"password_change_required">>}} = req(Config, get, "devices", B2),
    %% deleting a user ends their sessions
    {204, _, _} = req(Config, delete, "users/bob", A),
    {401, _, _} = req(Config, get, "me", B2),
    {404, _, _} = req(Config, get, "users/bob", A),
    {422, _, #{<<"errors">> := [_ | _]}} = req(Config, put, "users/bad%20name", A, #{role => viewer,
                                                                                    password => <<"password-1">>}).

last_admin_cannot_be_removed(Config) ->
    A = admin(Config),
    {409, _, #{<<"error">> := <<"last_admin">>}} = req(Config, delete, "users/admin", A),
    {422, _, #{<<"errors">> := [#{<<"error">> := <<"last_admin">>}]}} =
        req(Config, put, "users/admin", A, #{role => viewer}).

logout_ends_session(Config) ->
    A = admin(Config),
    {204, H, _} = req(Config, post, "logout", A),
    ?assertNotEqual(nomatch, string:find(string:lowercase(proplists:get_value("set-cookie", H)), "max-age=0")),
    {401, _, _} = req(Config, get, "me", A),
    {401, _, _} = req(Config, post, "logout", A).

status_of_devices_and_servers(Config) ->
    A = admin(Config),
    ok = wait(fun() ->
                      {200, _, #{<<"devices">> := [D], <<"servers">> := [Srv], <<"active_vsn">> := 3}} =
                          req(Config, get, "status", A),
                      #{<<"name">> := <<"sw-a">>, <<"enabled">> := true} = D,
                      #{<<"name">> := <<"scada">>, <<"state">> := <<"running">>} = Srv,
                      maps:get(<<"health">>, D) =:= <<"up">> andalso maps:get(<<"points">>, Srv) > 0
              end),
    {200, _, #{<<"health">> := <<"up">>, <<"cycles">> := _, <<"last_ok">> := LastOk, <<"error">> := null}} =
        req(Config, get, "status/devices/sw-a", A),
    ?assert(is_integer(LastOk)),
    {404, _, _} = req(Config, get, "status/devices/nope", A),
    {200, _, [#{<<"name">> := <<"scada">>}]} = req(Config, get, "status/servers", A).

snmp_tools_through_device(Config) ->
    A = admin(Config),
    Agent = ?config(agent, Config),
    ok = s2i_fake_agent:set(Agent, [1, 3, 6, 1, 4, 1, 99999, 3, 0], {'OCTET STRING', "hello"}),
    ok = s2i_fake_agent:set(Agent, [1, 3, 6, 1, 4, 1, 99999, 4, 0], {'OCTET STRING', [0, 255]}),
    {200, _, #{<<"varbinds">> := [V1, V2]}} =
        req(Config, post, "tools/snmp/get", A, #{device => <<"sw-a">>,
                                                 oids => [<<"1.3.6.1.4.1.99999.1.0">>, <<"1.3.6.1.4.1.99999.3.0">>]}),
    ?assertEqual(#{<<"oid">> => <<"1.3.6.1.4.1.99999.1.0">>, <<"type">> => <<"INTEGER">>, <<"value">> => 215}, V1),
    #{<<"value">> := <<"hello">>, <<"hex">> := <<"68656c6c6f">>} = V2,
    {200, _, #{<<"varbinds">> := Walked, <<"truncated">> := false}} =
        req(Config, post, "tools/snmp/walk", A, #{device => <<"sw-a">>, oid => <<"1.3.6.1.4.1.99999">>}),
    ?assertEqual([<<"1.3.6.1.4.1.99999.1.0">>, <<"1.3.6.1.4.1.99999.2.0">>, <<"1.3.6.1.4.1.99999.3.0">>,
                  <<"1.3.6.1.4.1.99999.4.0">>], [O || #{<<"oid">> := O} <- Walked]),
    #{<<"value">> := null, <<"hex">> := <<"00ff">>} = lists:last(Walked),
    {200, _, #{<<"varbinds">> := [_, _], <<"truncated">> := true}} =
        req(Config, post, "tools/snmp/walk", A, #{device => <<"sw-a">>, oid => <<"1.3.6.1.4.1.99999">>, max => 2}),
    {503, _, #{<<"error">> := <<"not_running">>}} =
        req(Config, post, "tools/snmp/get", A, #{device => <<"nope">>, oids => [<<"1.3.6.1.2.1.1.3.0">>]}),
    {422, _, #{<<"errors">> := [#{<<"path">> := [<<"oids">>, 1]}]}} =
        req(Config, post, "tools/snmp/get", A, #{device => <<"sw-a">>, oids => [<<"1.3.6">>, <<"x.y">>]}),
    {422, _, #{<<"errors">> := [#{<<"error">> := <<"too_many_oids">>}]}} =
        req(Config, post, "tools/snmp/get", A, #{device => <<"sw-a">>,
                                                 oids => lists:duplicate(31, <<"1.3.6.1.2.1.1.3.0">>)}),
    {400, _, _} = req(Config, post, "tools/snmp/walk", A, #{device => <<"sw-a">>}),
    %% an unanswered request: timeout after the device's retries
    ok = s2i_fake_agent:silent(Agent, true),
    {504, _, #{<<"error">> := <<"timeout">>}} =
        req(Config, post, "tools/snmp/get", A, #{device => <<"sw-a">>, oids => [<<"1.3.6.1.2.1.1.3.0">>]}),
    ok = s2i_fake_agent:silent(Agent, false).

-define(TEST_MIB, <<"TEST-MIB DEFINITIONS ::= BEGIN\n"
                   "IMPORTS MODULE-IDENTITY, OBJECT-TYPE, enterprises FROM SNMPv2-SMI;\n"
                   "testMIB MODULE-IDENTITY LAST-UPDATED \"202601010000Z\" ORGANIZATION \"x\"\n"
                   "    CONTACT-INFO \"x\" DESCRIPTION \"Test\" ::= { enterprises 99999 }\n"
                   "testState OBJECT-TYPE SYNTAX INTEGER { on(1), off(2) } MAX-ACCESS read-only\n"
                   "    STATUS current DESCRIPTION \"Breaker\" ::= { testMIB 1 }\n"
                   "END\n">>).

mib_library(Config) ->
    A = admin(Config),
    {200, _, Builtin} = req(Config, get, "mibs", A),
    ?assert(lists:member(#{<<"name">> => <<"SNMPv2-MIB">>, <<"origin">> => <<"builtin">>, <<"status">> => <<"ok">>},
                         [maps:with([<<"name">>, <<"origin">>, <<"status">>], M) || M <- Builtin])),
    {200, _, #{<<"modules">> := [#{<<"name">> := <<"TEST-MIB">>, <<"status">> := <<"ok">>,
                                   <<"uploaded_by">> := <<"admin">>}],
               <<"skipped">> := []}} =
        req(Config, post, "mibs", A, #{sources => [?TEST_MIB]}),
    {200, _, #{<<"origin">> := <<"uploaded">>, <<"objects">> := 2}} = req(Config, get, "mibs/TEST-MIB", A),
    {200, H, Source} = raw(Config, get, "mibs/TEST-MIB/source", [{"cookie", A}], <<>>),
    ?assertEqual(?TEST_MIB, Source),
    ?assertEqual("text/plain; charset=utf-8", proplists:get_value("content-type", H)),
    {404, _, _} = req(Config, get, "mibs/NOPE-MIB", A),
    %% the values the gateway polls, by name
    {200, _, #{<<"oids">> := [State, null, null, SysUpTime],
               <<"names">> := [#{<<"oid">> := <<"1.3.6.1.4.1.99999.1.0">>},
                               #{<<"error">> := <<"not_found">>}, #{<<"error">> := <<"invalid">>}]}} =
        req(Config, post, "oids/translate", A,
            #{oids => [<<"1.3.6.1.4.1.99999.1.0">>, <<"x.y">>, <<"7.7">>, <<"1.3.6.1.2.1.1.3.0">>],
              names => [<<"TEST-MIB::testState.0">>, <<"nope">>, 42]}),
    ?assertMatch(#{<<"name">> := <<"testState">>, <<"index">> := <<"0">>, <<"module">> := <<"TEST-MIB">>,
                   <<"enums">> := [#{<<"value">> := 1, <<"name">> := <<"on">>}, _]}, State),
    ?assertMatch(#{<<"name">> := <<"sysUpTime">>, <<"module">> := <<"SNMPv2-MIB">>}, SysUpTime),
    {422, _, _} = req(Config, post, "oids/translate", A, #{oids => lists:duplicate(1001, <<"1.3">>)}),
    {200, _, #{<<"def">> := #{<<"name">> := <<"testMIB">>, <<"kind">> := <<"node">>},
               <<"path">> := [#{<<"name">> := <<"iso">>} | _],
               <<"children">> := [#{<<"name">> := <<"testState">>, <<"has_children">> := false}]}} =
        req(Config, get, "oids/1.3.6.1.4.1.99999", A),
    {422, _, _} = req(Config, get, "oids/abc", A),
    {200, _, [#{<<"name">> := <<"testState">>, <<"oid">> := <<"1.3.6.1.4.1.99999.1">>}]} =
        req(Config, get, "oids?q=teststate", A),
    {400, _, _} = req(Config, get, "oids?q=", A),
    {422, _, _} = req(Config, get, "oids?q=x&limit=0", A),
    %% viewers read, admins change
    V = login(Config, <<"view">>, <<"viewer-password">>),
    {200, _, [_ | _]} = req(Config, get, "mibs", V),
    {403, _, _} = req(Config, post, "mibs", V, #{sources => [?TEST_MIB]}),
    {403, _, _} = req(Config, delete, "mibs/TEST-MIB", V),
    {422, _, #{<<"errors">> := [#{<<"path">> := [<<"sources">>, 0], <<"error">> := <<"no_module">>}]}} =
        req(Config, post, "mibs", A, #{source => <<"not a MIB">>}),
    {400, _, _} = req(Config, post, "mibs", A, #{}),
    {409, _, #{<<"error">> := <<"builtin">>}} = req(Config, delete, "mibs/SNMPv2-MIB", A),
    {204, _, _} = req(Config, delete, "mibs/TEST-MIB", A),
    {404, _, _} = req(Config, delete, "mibs/TEST-MIB", A),
    {200, _, #{<<"oids">> := [#{<<"name">> := <<"enterprises">>, <<"index">> := <<"99999.1.0">>}]}} =
        req(Config, post, "oids/translate", A, #{oids => [<<"1.3.6.1.4.1.99999.1.0">>]}),
    {200, _, [#{<<"action">> := <<"mib_delete">>, <<"name">> := <<"TEST-MIB">>} | _]} =
        req(Config, get, "config/audit?limit=1", A).

%%% --- WebSocket (§9.3) -------------------------------------------------------

ws_upgrade_needs_session_and_origin(Config) ->
    {error, 401} = ws_open(none, []),
    {error, 401} = ws_open("s2i_session=forged", []),
    A = admin(Config),
    {error, 403} = ws_open(A, [{<<"origin">>, <<"https://evil.example">>}]),
    {ok, W1} = ws_open(A, [{<<"origin">>, <<"http://127.0.0.1:1234">>}]),
    ws_close(W1),
    {ok, W2} = ws_open(A, []),                  % no Origin: not a browser
    ws_close(W2),
    %% a viewer may debug, a user with a pending password change may not
    V = login(Config, <<"view">>, <<"viewer-password">>),
    {ok, W3} = ws_open(V, []),
    ws_close(W3),
    {200, _, _} = req(Config, put, "users/fresh", A, #{role => viewer, password => <<"fresh-password">>}),
    F = login(Config, <<"fresh">>, <<"fresh-password">>),
    {error, 403} = ws_open(F, []),
    {204, _, _} = req(Config, delete, "users/fresh", A).

ws_protocol_errors_and_ping(Config) ->
    {ok, W} = ws_open(admin(Config), []),
    ws_send(W, #{op => ping}),
    #{<<"type">> := <<"pong">>} = ws_recv(W, <<"pong">>),
    ws_send(W, #{op => subscribe, topic => <<"secrets">>}),
    #{<<"error">> := <<"invalid_topic">>} = ws_recv(W, <<"error">>),
    ws_send_raw(W, <<"{not json">>),
    #{<<"error">> := <<"invalid_json">>} = ws_recv(W, <<"error">>),
    ws_send(W, #{op => subscribe, topic => <<"log">>, level => <<"loud">>}),
    #{<<"error">> := <<"invalid_level">>} = ws_recv(W, <<"error">>),
    [begin
         ws_send(W, #{op => subscribe, topic => <<"values:device:d", (integer_to_binary(I))/binary>>}),
         #{<<"type">> := <<"subscribed">>} = ws_recv(W, <<"subscribed">>)
     end || I <- lists:seq(1, 32)],
    ws_send(W, #{op => subscribe, topic => <<"traps">>}),
    #{<<"error">> := <<"too_many_subscriptions">>} = ws_recv(W, <<"error">>),
    ws_send(W, #{op => unsubscribe, topic => <<"values:device:d1">>}),
    #{<<"topic">> := <<"values:device:d1">>} = ws_recv(W, <<"unsubscribed">>),
    ws_close(W).

ws_device_values_and_trace(Config) ->
    Agent = ?config(agent, Config),
    {ok, W} = ws_open(admin(Config), []),
    ws_send(W, #{op => subscribe, topic => <<"values:device:sw-a">>}),
    #{<<"snapshot">> := [P]} = ws_recv(W, <<"subscribed">>),
    #{<<"server">> := <<"scada">>, <<"coa">> := 1, <<"ioa">> := 100, <<"source">> := <<"sw-a/temperature">>,
      <<"point">> := #{<<"type">> := <<"m_me_tf_1">>}} = P,
    ok = s2i_fake_agent:set(Agent, [1, 3, 6, 1, 4, 1, 99999, 1, 0], {'INTEGER', 230}),
    Ev = ws_recv(W, fun(#{<<"type">> := <<"event">>,
                          <<"event">> := #{<<"values">> := [#{<<"writes">> := [_]}]}}) -> true;
                       (_) -> false
                    end),
    #{<<"topic">> := <<"values:device:sw-a">>,
      <<"event">> := #{<<"source">> := <<"poll">>, <<"at">> := At,
                       <<"values">> := [#{<<"oid">> := <<"1.3.6.1.4.1.99999.1.0">>,
                                          <<"value">> := #{<<"type">> := <<"integer">>, <<"value">> := 230},
                                          <<"datapoints">> := [<<"sw-a/temperature">>],
                                          <<"writes">> := [#{<<"server">> := <<"scada">>, <<"ioa">> := 100,
                                                             <<"point">> := #{<<"value">> := Value}}]}]}} = Ev,
    true = is_integer(At),
    ?assert(abs(Value - 23.0) < 1.0e-6),
    %% SNMP trace: request and response of a poll
    ws_send(W, #{op => subscribe, topic => <<"snmp:trace:sw-a">>}),
    #{<<"history">> := []} = ws_recv(W, <<"subscribed">>),
    #{<<"event">> := #{<<"op">> := <<"get">>, <<"req_id">> := Id, <<"oids">> := Oids,
                       <<"purpose">> := #{<<"poll">> := <<"fast">>}}} =
        ws_recv(W, fun(#{<<"topic">> := <<"snmp:trace:sw-a">>, <<"event">> := #{<<"dir">> := <<"request">>}}) -> true;
                      (_) -> false
                   end),
    ?assert(lists:member(<<"1.3.6.1.4.1.99999.1.0">>, Oids)),
    #{<<"event">> := #{<<"error_status">> := <<"noError">>, <<"varbinds">> := [_ | _]}} =
        ws_recv(W, fun(#{<<"topic">> := <<"snmp:trace:sw-a">>,
                         <<"event">> := #{<<"dir">> := <<"response">>, <<"req_id">> := I}}) -> I =:= Id;
                      (_) -> false
                   end),
    ws_close(W).

ws_server_values_and_groups(Config) ->
    Agent = ?config(agent, Config),
    {ok, W} = ws_open(admin(Config), []),
    ws_send(W, #{op => subscribe, topic => <<"values:server:scada">>}),
    #{<<"snapshot">> := [#{<<"coa">> := 1, <<"ioa">> := 100, <<"type">> := <<"m_me_tf_1">>}]} =
        ws_recv(W, <<"subscribed">>),
    ok = s2i_fake_agent:set(Agent, [1, 3, 6, 1, 4, 1, 99999, 1, 0], {'INTEGER', 240}),
    #{<<"event">> := #{<<"points">> := [#{<<"ioa">> := 100, <<"quality">> := []}]}} =
        ws_recv(W, fun(#{<<"topic">> := <<"values:server:scada">>, <<"type">> := <<"event">>}) -> true;
                      (_) -> false
                   end),
    %% iec:<server>: groups at once and then periodically; a connection is an event
    ws_send(W, #{op => subscribe, topic => <<"iec:scada">>}),
    #{<<"groups">> := G0} = ws_recv(W, <<"subscribed">>),
    ?assert(is_list(G0)),
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, ?config(iec_port, Config), [binary, {active, false}]),
    ok = gen_tcp:send(Sock, <<16#68, 4, 16#07, 0, 0, 0>>),     % STARTDT act
    {ok, <<16#68, 4, 16#0B, 0, 0, 0>>} = gen_tcp:recv(Sock, 6, 5000),
    #{<<"event">> := #{<<"event">> := <<"activated">>, <<"conn">> := <<"<", _/binary>>}} =
        ws_recv(W, fun(#{<<"topic">> := <<"iec:scada">>, <<"type">> := <<"event">>}) -> true;
                      (_) -> false
                   end),
    #{<<"groups">> := [#{<<"active">> := true, <<"members">> := 1}]} =
        ws_recv(W, fun(#{<<"type">> := <<"groups">>, <<"groups">> := [_]}) -> true;
                      (_) -> false
                   end, 5000),
    ok = gen_tcp:close(Sock),
    ws_close(W),
    %% the history of iec:scada now holds the connection events
    {ok, W2} = ws_open(admin(Config), []),
    ws_send(W2, #{op => subscribe, topic => <<"iec:scada">>}),
    #{<<"history">> := [#{<<"event">> := <<"activated">>} | _]} = ws_recv(W2, <<"subscribed">>),
    ws_close(W2),
    %% REST status shows the groups as well
    {200, _, [#{<<"groups">> := Groups}]} = req(Config, get, "status/servers", admin(Config)),
    ?assert(is_list(Groups)).

ws_traps_with_history(Config) ->
    Agent = ?config(agent, Config),
    {ok, W} = ws_open(admin(Config), []),
    ws_send(W, #{op => subscribe, topic => <<"traps">>}),
    #{<<"history">> := H0} = ws_recv(W, <<"subscribed">>),
    To = {{127, 0, 0, 1}, application:get_env(s2i_snmp, port, 162)},
    ok = s2i_fake_agent:notify(Agent, To, #{version => v2c, trap => [1, 3, 6, 1, 4, 1, 99999, 0, 1],
                                            varbinds => [{[1, 3, 6, 1, 4, 1, 99999, 1, 0], 'INTEGER', 250}]}),
    #{<<"event">> := #{<<"device">> := <<"sw-a">>, <<"trap_oid">> := <<"1.3.6.1.4.1.99999.0.1">>,
                       <<"matched">> := [<<"varbind">>],
                       <<"varbinds">> := [#{<<"oid">> := <<"1.3.6.1.4.1.99999.1.0">>, <<"value">> := 250}]}} =
        ws_recv(W, fun(#{<<"topic">> := <<"traps">>, <<"type">> := <<"event">>}) -> true;
                      (_) -> false
                   end),
    ws_close(W),
    {ok, W2} = ws_open(admin(Config), []),
    ws_send(W2, #{op => subscribe, topic => <<"traps">>}),
    #{<<"history">> := H1} = ws_recv(W2, <<"subscribed">>),
    ?assertEqual(length(H0) + 1, length(H1)),
    ws_close(W2).

ws_log_with_level(Config) ->
    {ok, W} = ws_open(admin(Config), []),
    ws_send(W, #{op => subscribe, topic => <<"log">>, level => <<"warning">>}),
    #{<<"history">> := History} = ws_recv(W, <<"subscribed">>),
    [?assertNotEqual(<<"info">>, L) || #{<<"level">> := L} <- History],
    logger:info("ws suite: info is filtered"),
    logger:warning("ws suite: warning passes"),
    #{<<"event">> := #{<<"level">> := <<"warning">>}} =
        ws_recv(W, fun(#{<<"topic">> := <<"log">>, <<"event">> := #{<<"msg">> := M}}) ->
                           M =:= <<"ws suite: info is filtered">> andalso error(info_not_filtered),
                           M =:= <<"ws suite: warning passes">>;
                      (_) -> false
                   end),
    ws_close(W).

ws_closed_when_session_ends(Config) ->
    A = admin(Config),
    {ok, W} = ws_open(A, []),
    ws_send(W, #{op => ping}),
    _ = ws_recv(W, <<"pong">>),
    {204, _, _} = req(Config, post, "logout", A),
    {4001, _} = ws_wait_close(W, 5000).

%%% --- static UI ----------------------------------------------------------------

static_ui_and_spa_fallback(Config) ->
    Root = "http://127.0.0.1:" ++ integer_to_list(s2i_web_sup:port(http)),
    Get = fun(Path) ->
                  {ok, {{_, St, _}, H, B}} = httpc:request(get, {Root ++ Path, []}, [], [{body_format, binary}]),
                  {St, H, B}
          end,
    %% no build: a hint, the API still works
    ok = application:set_env(s2i_web, www_dir, filename:join(?config(priv_dir, Config), "no-www")),
    {404, _, Hint} = Get("/"),
    ?assertNotEqual(nomatch, binary:match(Hint, <<"npm run build">>)),
    Www = filename:join(?config(priv_dir, Config), "www"),
    ok = filelib:ensure_dir(filename:join([Www, "assets", "x"])),
    ok = file:write_file(filename:join(Www, "index.html"), <<"<!doctype html><title>ui</title>">>),
    ok = file:write_file(filename:join([Www, "assets", "app-1234.js"]), <<"console.log(1)">>),
    ok = application:set_env(s2i_web, www_dir, Www),
    try
        {200, H1, <<"<!doctype html>", _/binary>>} = Get("/"),
        "text/html" ++ _ = proplists:get_value("content-type", H1),
        "no-cache" = proplists:get_value("cache-control", H1),
        "DENY" = proplists:get_value("x-frame-options", H1),
        "default-src 'self'" ++ _ = proplists:get_value("content-security-policy", H1),
        %% client-side routes get the index
        {200, _, <<"<!doctype html>", _/binary>>} = Get("/devices/sw-a"),
        {200, H2, <<"console.log(1)">>} = Get("/assets/app-1234.js"),
        ?assertNotEqual(nomatch, string:find(proplists:get_value("content-type", H2), "javascript")),
        "public, max-age=31536000, immutable" = proplists:get_value("cache-control", H2),
        {404, _, _} = Get("/assets/missing.js"),
        {404, _, _} = Get("/favicon.ico"),
        {404, _, _} = Get("/%2e%2e/%2e%2e/etc/passwd.txt"),
        {404, _, _} = Get("/.hidden"),
        %% the API is not shadowed
        {401, _, _} = Get("/api/v1/devices")
    after
        application:unset_env(s2i_web, www_dir)
    end.

idle_session_expires(Config) ->
    ok = application:set_env(s2i_web, session_idle_timeout, 300),
    try
        A = admin(Config),
        {200, _, _} = req(Config, get, "me", A),
        timer:sleep(150),
        {200, _, _} = req(Config, get, "me", A),     % activity keeps it alive
        timer:sleep(150),
        {200, _, _} = req(Config, get, "me", A),
        timer:sleep(400),
        {401, _, _} = req(Config, get, "me", A)
    after
        ok = application:unset_env(s2i_web, session_idle_timeout)
    end.

openapi_is_public(Config) ->
    {200, _, #{<<"openapi">> := <<"3.1.0">>, <<"paths">> := #{<<"/devices/{name}">> := _}}} =
        req(Config, get, "openapi.json", none).

%%% ===========================================================================
%%% Fixtures
%%% ===========================================================================

server(Port) ->
    #{name => <<"scada">>, transport => #{kind => tcp, ip => <<"127.0.0.1">>, port => Port},
      common_addresses => [1]}.

profile() ->
    #{name => ?PROFILE, poll_groups => #{<<"fast">> => 1000},
      datapoints => [#{name => <<"temperature">>, oid => <<"1.3.6.1.4.1.99999.1.0">>, poll_group => <<"fast">>,
                       mappings => [#{ioa_offset => 0, type => m_me_tf_1,
                                      transform => #{kind => linear, scale => 0.1}}]}]}.

device(Port) ->
    #{name => <<"sw-a">>, host => <<"127.0.0.1">>, port => Port,
      snmp => #{version => v2c, community => <<"public">>},
      timeout => 300, retries => 1, profile => ?PROFILE, ioa_base => 100,
      targets => #{<<"default">> => [#{server => <<"scada">>, coa => 1}]}}.

%%% ===========================================================================
%%% WebSocket helpers (gun)
%%% ===========================================================================

ws_open(Cookie, Headers) ->
    {ok, C} = gun:open("127.0.0.1", s2i_web_sup:port(http), #{protocols => [http], retry => 0}),
    {ok, http} = gun:await_up(C, 5000),
    Ref = gun:ws_upgrade(C, "/ws", [{<<"cookie">>, list_to_binary(Cookie)} || Cookie =/= none] ++ Headers),
    receive
        {gun_upgrade, C, Ref, [<<"websocket">>], _} ->
            {ok, {C, Ref}};
        {gun_response, C, Ref, _, Status, _} ->
            gun:close(C),
            {error, Status}
    after 5000 ->
            error(ws_upgrade_timeout)
    end.

ws_close({C, _Ref}) ->
    gun:close(C).

ws_send(W, Msg) ->
    ws_send_raw(W, iolist_to_binary(json:encode(Msg))).

ws_send_raw({C, Ref}, Bin) ->
    ok = gun:ws_send(C, Ref, {text, Bin}).

%% The next message of `Type` (or matching `Pred`); others are skipped.
ws_recv(W, Type) when is_binary(Type) ->
    ws_recv(W, fun(#{<<"type">> := T}) -> T =:= Type end);
ws_recv(W, Pred) ->
    ws_recv(W, Pred, 10000).

ws_recv({C, Ref} = W, Pred, Timeout) ->
    receive
        {gun_ws, C, Ref, {text, Bin}} ->
            Msg = json:decode(Bin),
            case Pred(Msg) of
                true -> Msg;
                false -> ws_recv(W, Pred, Timeout)
            end
    after Timeout ->
            error(ws_recv_timeout)
    end.

ws_wait_close({C, Ref} = W, Timeout) ->
    receive
        {gun_ws, C, Ref, {close, Code, Reason}} -> {Code, Reason};
        {gun_ws, C, Ref, _} -> ws_wait_close(W, Timeout)
    after Timeout ->
            error(ws_close_timeout)
    end.

%%% ===========================================================================
%%% HTTP helpers
%%% ===========================================================================

admin(Config) -> login(Config, <<"admin">>, ?ADMIN_PW).

login(Config, User, Password) ->
    {200, H, _} = req(Config, post, "login", none, #{username => User, password => Password}),
    cookie(H).

cookie(Headers) ->
    [Pair | _] = string:split(proplists:get_value("set-cookie", Headers), ";"),
    Pair.

csrf() -> {"x-requested-with", "test"}.

req(Config, Method, Path, Cookie) ->
    req(Config, Method, Path, Cookie, undefined).

req(Config, Method, Path, Cookie, Body) ->
    Headers = [csrf() | [{"cookie", Cookie} || Cookie =/= none]],
    raw(Config, Method, Path, Headers, case Body of
                                            undefined -> <<>>;
                                            _ -> iolist_to_binary(json:encode(Body))
                                        end).

raw(Config, Method, Path, Headers, Body) ->
    Url = ?config(base, Config) ++ Path,
    Request = case Method of
                  M when M =:= get; M =:= delete -> {Url, Headers};
                  _ -> {Url, Headers, "application/json", Body}
              end,
    {ok, {{_, Status, _}, RespHeaders, RespBody}} =
        httpc:request(Method, Request, [{timeout, 30000}], [{body_format, binary}]),
    Decoded = case {RespBody, proplists:get_value("content-type", RespHeaders)} of
                  {<<>>, _} -> none;
                  {_, "text/plain" ++ _} -> RespBody;
                  _ -> json:decode(RespBody)
              end,
    {Status, RespHeaders, Decoded}.

wait(Fun) -> wait(Fun, 100).

wait(_Fun, 0) -> ct:fail(condition_not_met);
wait(Fun, N) ->
    case catch Fun() of
        true -> ok;
        _ -> timer:sleep(100), wait(Fun, N - 1)
    end.

free_udp_port() ->
    {ok, S} = gen_udp:open(0, [{ip, {127, 0, 0, 1}}]),
    {ok, P} = inet:port(S),
    ok = gen_udp:close(S),
    P.

free_tcp_port() ->
    {ok, L} = gen_tcp:listen(0, []),
    {ok, P} = inet:port(L),
    ok = gen_tcp:close(L),
    P.
