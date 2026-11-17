-module(s2i_web_SUITE).
-moduledoc """
REST API end to end (docs/DESIGN.md §9.1, §9.2): the whole gateway with an
HTTP listener on a free port, driven with `httpc`. The cases share one
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
    {200, _, #{<<"health">> := <<"up">>, <<"cycles">> := _}} = req(Config, get, "status/devices/sw-a", A),
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
    Decoded = case RespBody of
                  <<>> -> none;
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
