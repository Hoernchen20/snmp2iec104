-module(s2i_web_rest_tests).
-include_lib("eunit/include/eunit.hrl").

-define(ADMIN, #{role => admin, must_change_password => false}).
-define(VIEWER, #{role => viewer, must_change_password => false}).
-define(FORCED, #{role => admin, must_change_password => true}).

p(Path) -> binary:split(Path, <<"/">>, [global]).

entity_routes_test() ->
    ?assertEqual({ok, {list, device}, viewer}, s2i_web_rest:route(<<"GET">>, p(<<"devices">>))),
    ?assertEqual({ok, {get, server, <<"scada">>}, viewer},
                 s2i_web_rest:route(<<"GET">>, p(<<"servers/scada">>))),
    ?assertEqual({ok, {put, profile, <<"switch">>}, admin},
                 s2i_web_rest:route(<<"PUT">>, p(<<"profiles/switch">>))),
    ?assertEqual({ok, {delete, device, <<"sw1">>}, admin},
                 s2i_web_rest:route(<<"DELETE">>, p(<<"devices/sw1">>))).

bound_segments_test() ->
    ?assertEqual({ok, {version, <<"3">>}, viewer}, s2i_web_rest:route(<<"GET">>, p(<<"config/versions/3">>))),
    ?assertEqual({ok, {restore, <<"3">>}, admin},
                 s2i_web_rest:route(<<"POST">>, p(<<"config/versions/3/restore">>))),
    ?assertEqual({ok, {user_put, <<"bob">>}, admin}, s2i_web_rest:route(<<"PUT">>, p(<<"users/bob">>))),
    ?assertEqual({ok, {device_status, <<"sw1">>}, viewer},
                 s2i_web_rest:route(<<"GET">>, p(<<"status/devices/sw1">>))).

plain_routes_test() ->
    ?assertEqual({ok, login, public}, s2i_web_rest:route(<<"POST">>, [<<"login">>])),
    ?assertEqual({ok, change_password, session}, s2i_web_rest:route(<<"POST">>, p(<<"me/password">>))),
    ?assertEqual({ok, activate, admin}, s2i_web_rest:route(<<"POST">>, p(<<"config/activate">>))),
    ?assertEqual({ok, snmp_walk, viewer}, s2i_web_rest:route(<<"POST">>, p(<<"tools/snmp/walk">>))).

mib_routes_test() ->
    ?assertEqual({ok, mib_upload, admin}, s2i_web_rest:route(<<"POST">>, p(<<"mibs">>))),
    ?assertEqual({ok, {mib_delete, <<"IF-MIB">>}, admin}, s2i_web_rest:route(<<"DELETE">>, p(<<"mibs/IF-MIB">>))),
    ?assertEqual({ok, {mib_source, <<"IF-MIB">>}, viewer},
                 s2i_web_rest:route(<<"GET">>, p(<<"mibs/IF-MIB/source">>))),
    ?assertEqual({ok, oid_translate, viewer}, s2i_web_rest:route(<<"POST">>, p(<<"oids/translate">>))),
    ?assertEqual({ok, {oid_node, <<"1.3.6.1">>}, viewer}, s2i_web_rest:route(<<"GET">>, p(<<"oids/1.3.6.1">>))),
    ?assertEqual({ok, oid_search, viewer}, s2i_web_rest:route(<<"GET">>, p(<<"oids">>))).

head_is_get_test() ->
    ?assertEqual({ok, {list, device}, viewer}, s2i_web_rest:route(<<"HEAD">>, p(<<"devices">>))).

unknown_routes_test() ->
    ?assertEqual({error, not_found}, s2i_web_rest:route(<<"GET">>, p(<<"nope">>))),
    ?assertEqual({error, not_found}, s2i_web_rest:route(<<"GET">>, p(<<"devices/a/b">>))),
    ?assertEqual({error, not_found}, s2i_web_rest:route(<<"GET">>, [<<"devices">>, <<>>])),
    ?assertEqual({error, {method_not_allowed, [<<"POST">>]}},
                 s2i_web_rest:route(<<"GET">>, [<<"login">>])),
    ?assertEqual({error, {method_not_allowed, [<<"GET">>]}},
                 s2i_web_rest:route(<<"POST">>, [<<"devices">>])).

every_route_has_a_valid_access_test() ->
    [?assert(lists:member(A, [public, session, viewer, admin]))
     || {_, Ms} <- s2i_web_rest:routes(), {_, _, A} <- Ms].

only_login_and_description_are_public_test() ->
    Public = lists:sort([Act || {_, Ms} <- s2i_web_rest:routes(), {_, Act, public} <- Ms]),
    ?assertEqual([login, openapi], Public).

mutations_need_admin_test() ->
    %% everything that writes configuration or users is admin-only
    Writes = [{M, Act, A} || {_, Ms} <- s2i_web_rest:routes(), {M, Act, A} <- Ms,
                             M =:= <<"PUT">> orelse M =:= <<"DELETE">>],
    [?assertEqual(admin, A) || {_, _, A} <- Writes],
    [?assertEqual(admin, A) || {_, Ms} <- s2i_web_rest:routes(), {_, Act, A} <- Ms,
                               lists:member(Act, [activate, revert, import, restore, mib_upload])].

access_test() ->
    Csrf = #{csrf => true},
    ?assertEqual(ok, s2i_web_rest:check(public, <<"POST">>, {anonymous, Csrf})),
    ?assertEqual({error, unauthenticated}, s2i_web_rest:check(viewer, <<"GET">>, {anonymous, Csrf})),
    ?assertEqual(ok, s2i_web_rest:check(viewer, <<"GET">>, {?VIEWER, Csrf})),
    ?assertEqual({error, forbidden}, s2i_web_rest:check(admin, <<"PUT">>, {?VIEWER, Csrf})),
    ?assertEqual(ok, s2i_web_rest:check(admin, <<"PUT">>, {?ADMIN, Csrf})).

forced_password_change_test() ->
    Csrf = #{csrf => true},
    ?assertEqual({error, password_change_required}, s2i_web_rest:check(viewer, <<"GET">>, {?FORCED, Csrf})),
    ?assertEqual({error, password_change_required}, s2i_web_rest:check(admin, <<"PUT">>, {?FORCED, Csrf})),
    ?assertEqual(ok, s2i_web_rest:check(session, <<"POST">>, {?FORCED, Csrf})).

csrf_header_required_for_mutations_test() ->
    No = #{csrf => false},
    ?assertEqual({error, csrf}, s2i_web_rest:check(admin, <<"PUT">>, {?ADMIN, No})),
    ?assertEqual({error, csrf}, s2i_web_rest:check(public, <<"POST">>, {anonymous, No})),
    ?assertEqual({error, csrf}, s2i_web_rest:check(admin, <<"DELETE">>, {?ADMIN, No})),
    ?assertEqual(ok, s2i_web_rest:check(viewer, <<"GET">>, {?VIEWER, No})),
    ?assertEqual(ok, s2i_web_rest:check(viewer, <<"HEAD">>, {?VIEWER, No})).

status_codes_test() ->
    ?assertEqual(401, s2i_web_rest:status(unauthenticated)),
    ?assertEqual(403, s2i_web_rest:status(csrf)),
    ?assertEqual(422, s2i_web_rest:status(invalid)),
    ?assertEqual(500, s2i_web_rest:status(something_else)).
