-module(s2i_users_SUITE).
-moduledoc "s2i_users: web users in Mnesia (create, update, roles, passwords, bootstrap).".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([create_and_authenticate/1,
         hash_is_never_returned/1,
         create_requires_role_and_password/1,
         invalid_fields_are_rejected/1,
         update_role_keeps_password/1,
         password_set_by_admin_must_be_changed/1,
         change_own_password/1,
         last_admin_is_protected/1,
         delete_user/1,
         bootstrap_admin_only_without_users/1,
         weak_hash_is_renewed_on_login/1,
         changes_are_audited/1]).

all() ->
    [create_and_authenticate,
     hash_is_never_returned,
     create_requires_role_and_password,
     invalid_fields_are_rejected,
     update_role_keeps_password,
     password_set_by_admin_must_be_changed,
     change_own_password,
     last_admin_is_protected,
     delete_user,
     bootstrap_admin_only_without_users,
     weak_hash_is_renewed_on_login,
     changes_are_audited].

init_per_testcase(TC, Config) ->
    Dir = filename:join(?config(priv_dir, Config), atom_to_list(TC)),
    ok = filelib:ensure_path(Dir),
    ok = application:set_env(mnesia, dir, Dir),
    ok = application:set_env(s2i_core, password_iterations, 1000),
    ok = s2i_config_store:start(),
    Config.

end_per_testcase(_TC, _Config) ->
    stopped = mnesia:stop(),
    ok = application:unset_env(s2i_core, password_iterations),
    ok.

-define(ADMIN, <<"admin">>).
-define(PW, <<"secret-password">>).

admin() ->
    {ok, _} = s2i_users:put(?ADMIN, #{<<"role">> => <<"admin">>, <<"password">> => ?PW,
                                      <<"must_change_password">> => false}, <<"system">>),
    ok.

%%% cases

create_and_authenticate(_Config) ->
    ok = admin(),
    {ok, #{name := ?ADMIN, role := admin}} = s2i_users:authenticate(?ADMIN, ?PW),
    ?assertEqual({error, invalid_credentials}, s2i_users:authenticate(?ADMIN, <<"wrong-password">>)),
    ?assertEqual({error, invalid_credentials}, s2i_users:authenticate(<<"nobody">>, ?PW)),
    ?assertEqual({error, invalid_credentials}, s2i_users:authenticate(?ADMIN, 42)).

hash_is_never_returned(_Config) ->
    ok = admin(),
    {ok, U} = s2i_users:get(?ADMIN),
    ?assertNot(is_map_key(password, U)),
    [L] = s2i_users:list(),
    ?assertNot(is_map_key(password, L)),
    %% sorted by name, not by map contents
    {ok, _} = s2i_users:put(<<"zed">>, #{role => viewer, password => ?PW}, ?ADMIN),
    {ok, _} = s2i_users:put(<<"bob">>, #{role => admin, password => ?PW, must_change_password => false}, ?ADMIN),
    ?assertEqual([?ADMIN, <<"bob">>, <<"zed">>], [N || #{name := N} <- s2i_users:list()]),
    {ok, A} = s2i_users:authenticate(?ADMIN, ?PW),
    ?assertNot(is_map_key(password, A)).

create_requires_role_and_password(_Config) ->
    {error, Errors} = s2i_users:put(<<"bob">>, #{}, ?ADMIN),
    ?assertEqual(lists:sort([[role], [password]]), lists:sort([P || #{path := P} <- Errors])),
    ?assertEqual({error, not_found}, s2i_users:get(<<"bob">>)).

invalid_fields_are_rejected(_Config) ->
    {error, E1} = s2i_users:put(<<"bad name">>, #{role => viewer, password => ?PW}, ?ADMIN),
    ?assertMatch([#{path := [name], error := invalid_name}], E1),
    {error, E2} = s2i_users:put(<<"bob">>, #{role => <<"root">>, password => <<"short">>,
                                            <<"shoe_size">> => 44}, ?ADMIN),
    ?assertEqual(lists:sort([{[role], invalid_value}, {[password], too_short},
                             {[<<"shoe_size">>], unknown_field}]),
                 lists:sort([{P, C} || #{path := P, error := C} <- E2])),
    {error, E3} = s2i_users:put(<<"bob">>, #{name => <<"alice">>, role => viewer, password => ?PW}, ?ADMIN),
    ?assertMatch([#{path := [name], error := name_mismatch}], E3),
    ?assertEqual({error, [#{path => [], error => invalid_type}]}, s2i_users:put(<<"bob">>, [], ?ADMIN)).

update_role_keeps_password(_Config) ->
    ok = admin(),
    {ok, _} = s2i_users:put(<<"bob">>, #{role => viewer, password => ?PW, must_change_password => false}, ?ADMIN),
    {ok, #{role := admin, must_change_password := false}} = s2i_users:put(<<"bob">>, #{role => admin}, ?ADMIN),
    {ok, #{role := admin}} = s2i_users:authenticate(<<"bob">>, ?PW).

password_set_by_admin_must_be_changed(_Config) ->
    ok = admin(),
    {ok, #{must_change_password := true}} = s2i_users:put(<<"bob">>, #{role => viewer, password => ?PW}, ?ADMIN),
    ok = s2i_users:change_password(<<"bob">>, ?PW, <<"bobs-own-password">>),
    {ok, #{must_change_password := false}} = s2i_users:get(<<"bob">>),
    %% reset by the admin: forced again
    {ok, #{must_change_password := true}} = s2i_users:put(<<"bob">>, #{password => <<"reset-password">>}, ?ADMIN),
    %% a user setting their own password through put/3 is not forced
    {ok, #{must_change_password := false}} = s2i_users:put(?ADMIN, #{password => <<"admin-password-2">>}, ?ADMIN).

change_own_password(_Config) ->
    ok = admin(),
    ?assertEqual({error, invalid_credentials},
                 s2i_users:change_password(?ADMIN, <<"wrong-password">>, <<"new-password">>)),
    ?assertMatch({error, [#{path := [new_password], error := too_short}]},
                 s2i_users:change_password(?ADMIN, ?PW, <<"short">>)),
    ?assertMatch({error, [#{path := [new_password], error := unchanged}]},
                 s2i_users:change_password(?ADMIN, ?PW, ?PW)),
    ok = s2i_users:change_password(?ADMIN, ?PW, <<"new-password">>),
    ?assertEqual({error, invalid_credentials}, s2i_users:authenticate(?ADMIN, ?PW)),
    {ok, _} = s2i_users:authenticate(?ADMIN, <<"new-password">>).

last_admin_is_protected(_Config) ->
    ok = admin(),
    ?assertEqual({error, last_admin}, s2i_users:delete(?ADMIN, ?ADMIN)),
    ?assertMatch({error, [#{path := [role], error := last_admin}]},
                 s2i_users:put(?ADMIN, #{role => viewer}, ?ADMIN)),
    {ok, _} = s2i_users:put(<<"second">>, #{role => admin, password => ?PW}, ?ADMIN),
    {ok, #{role := viewer}} = s2i_users:put(?ADMIN, #{role => viewer}, <<"second">>),
    ?assertEqual({error, last_admin}, s2i_users:delete(<<"second">>, <<"second">>)).

delete_user(_Config) ->
    ok = admin(),
    {ok, _} = s2i_users:put(<<"bob">>, #{role => viewer, password => ?PW}, ?ADMIN),
    ok = s2i_users:delete(<<"bob">>, ?ADMIN),
    ?assertEqual({error, not_found}, s2i_users:get(<<"bob">>)),
    ?assertEqual({error, not_found}, s2i_users:delete(<<"bob">>, ?ADMIN)),
    ?assertEqual({error, invalid_credentials}, s2i_users:authenticate(<<"bob">>, ?PW)).

bootstrap_admin_only_without_users(_Config) ->
    created = s2i_users:ensure_admin(?ADMIN, ?PW),
    {ok, #{role := admin, must_change_password := true}} = s2i_users:get(?ADMIN),
    exists = s2i_users:ensure_admin(<<"other">>, ?PW),
    ?assertEqual({error, not_found}, s2i_users:get(<<"other">>)),
    %% users persist across a Mnesia restart
    stopped = mnesia:stop(),
    ok = s2i_config_store:start(),
    {ok, _} = s2i_users:authenticate(?ADMIN, ?PW).

weak_hash_is_renewed_on_login(_Config) ->
    ok = admin(),
    [{_, _, _, #{password := #{iterations := 1000}}}] = mnesia:dirty_read(s2i_user, ?ADMIN),
    ok = application:set_env(s2i_core, password_iterations, 2000),
    {ok, _} = s2i_users:authenticate(?ADMIN, ?PW),
    [{_, _, _, #{password := #{iterations := 2000}}}] = mnesia:dirty_read(s2i_user, ?ADMIN),
    {ok, _} = s2i_users:authenticate(?ADMIN, ?PW).

changes_are_audited(_Config) ->
    ok = admin(),
    {ok, _} = s2i_users:put(<<"bob">>, #{role => viewer, password => ?PW}, ?ADMIN),
    ok = s2i_users:change_password(<<"bob">>, ?PW, <<"bobs-own-password">>),
    ok = s2i_users:delete(<<"bob">>, ?ADMIN),
    Raw = mnesia:async_dirty(fun() -> s2i_config_store:list_audit(10) end),
    Entries = [{A, Act, N} || #{actor := A, action := Act, kind := user, name := N} <- lists:reverse(Raw)],
    ?assertEqual([{<<"system">>, user_put, ?ADMIN}, {?ADMIN, user_put, <<"bob">>},
                  {<<"bob">>, password_change, <<"bob">>}, {?ADMIN, user_delete, <<"bob">>}], Entries),
    %% no password material in the audit log
    ?assertEqual(nomatch, binary:match(term_to_binary(Raw), ?PW)).
