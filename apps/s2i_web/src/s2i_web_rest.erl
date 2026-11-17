-module(s2i_web_rest).
-moduledoc """
Route table and access rules of the REST API `/api/v1` (pure, docs/DESIGN.md §9).

`route/2` maps a method and the path segments below `/api/v1` to an action
and the access it needs:

| Access | Who |
|---|---|
| `public` | anyone (login, API description) |
| `session` | any logged-in user, also while a password change is pending |
| `viewer` | logged-in users without a pending password change |
| `admin` | admins without a pending password change |

`check/3` applies the access level and the CSRF rule: every method except
`GET`/`HEAD` must carry the `X-Requested-With` header (a header a
cross-site form cannot set; together with the `SameSite=Strict` cookie).
""".

-export([route/2, check/3, routes/0, status/1]).
-export_type([action/0, access/0]).

-type access() :: public | session | viewer | admin.
-type action() :: atom() | {atom(), term()} | {atom(), term(), term()}.
-type method() :: binary().
-type role() :: admin | viewer.
-type caller() :: anonymous | #{role := role(), must_change_password := boolean()}.

%% {Path pattern, [{Method, Action, Access}]}; atoms in a pattern bind a segment.
-spec routes() -> [{[binary() | atom()], [{method(), atom(), access()}]}].
routes() ->
    Entity = fun(Plural) ->
                     [{[Plural], [{<<"GET">>, list, viewer}]},
                      {[Plural, name], [{<<"GET">>, get, viewer},
                                        {<<"PUT">>, put, admin},
                                        {<<"DELETE">>, delete, admin}]}]
             end,
    [{[<<"login">>], [{<<"POST">>, login, public}]},
     {[<<"logout">>], [{<<"POST">>, logout, session}]},
     {[<<"me">>], [{<<"GET">>, me, session}]},
     {[<<"me">>, <<"password">>], [{<<"POST">>, change_password, session}]},
     {[<<"openapi.json">>], [{<<"GET">>, openapi, public}]}]
    ++ Entity(<<"servers">>) ++ Entity(<<"devices">>) ++ Entity(<<"profiles">>)
    ++ [{[<<"users">>], [{<<"GET">>, user_list, admin}]},
        {[<<"users">>, name], [{<<"GET">>, user_get, admin},
                               {<<"PUT">>, user_put, admin},
                               {<<"DELETE">>, user_delete, admin}]},
        {[<<"config">>, <<"staged">>], [{<<"GET">>, staged, viewer}]},
        {[<<"config">>, <<"active">>], [{<<"GET">>, active, viewer}]},
        {[<<"config">>, <<"validate">>], [{<<"POST">>, validate, viewer}]},
        {[<<"config">>, <<"activate">>], [{<<"POST">>, activate, admin}]},
        {[<<"config">>, <<"revert">>], [{<<"POST">>, revert, admin}]},
        {[<<"config">>, <<"export">>], [{<<"GET">>, export, viewer}]},
        {[<<"config">>, <<"import">>], [{<<"POST">>, import, admin}]},
        {[<<"config">>, <<"audit">>], [{<<"GET">>, audit, viewer}]},
        {[<<"config">>, <<"versions">>], [{<<"GET">>, versions, viewer}]},
        {[<<"config">>, <<"versions">>, vsn], [{<<"GET">>, version, viewer}]},
        {[<<"config">>, <<"versions">>, vsn, <<"restore">>], [{<<"POST">>, restore, admin}]},
        {[<<"status">>], [{<<"GET">>, status, viewer}]},
        {[<<"status">>, <<"devices">>], [{<<"GET">>, device_status_list, viewer}]},
        {[<<"status">>, <<"devices">>, name], [{<<"GET">>, device_status, viewer}]},
        {[<<"status">>, <<"servers">>], [{<<"GET">>, server_status_list, viewer}]},
        {[<<"tools">>, <<"snmp">>, <<"get">>], [{<<"POST">>, snmp_get, viewer}]},
        {[<<"tools">>, <<"snmp">>, <<"walk">>], [{<<"POST">>, snmp_walk, viewer}]},
        {[<<"mibs">>], [{<<"GET">>, mib_list, viewer}, {<<"POST">>, mib_upload, admin}]},
        {[<<"mibs">>, name], [{<<"GET">>, mib_get, viewer}, {<<"DELETE">>, mib_delete, admin}]},
        {[<<"mibs">>, name, <<"source">>], [{<<"GET">>, mib_source, viewer}]},
        {[<<"oids">>], [{<<"GET">>, oid_search, viewer}]},
        {[<<"oids">>, <<"translate">>], [{<<"POST">>, oid_translate, viewer}]},
        {[<<"oids">>, oid], [{<<"GET">>, oid_node, viewer}]}].

-doc """
The action for a request. Entity actions carry their kind
(`{get, device, Name}`), other bound segments are appended
(`{version, Vsn}`, `{user_get, Name}`).
""".
-spec route(method(), [binary()]) ->
          {ok, action(), access()} | {error, not_found} | {error, {method_not_allowed, [method()]}}.
route(<<"HEAD">>, Path) ->
    route(<<"GET">>, Path);
route(Method, Path) ->
    case match(Path, routes()) of
        {ok, Binds, Methods} ->
            case lists:keyfind(Method, 1, Methods) of
                {_, Action, Access} -> {ok, action(Action, Path, Binds), Access};
                false -> {error, {method_not_allowed, [M || {M, _, _} <- Methods]}}
            end;
        error ->
            {error, not_found}
    end.

match(_Path, []) ->
    error;
match(Path, [{Pattern, Methods} | Rest]) ->
    case bind(Pattern, Path, []) of
        {ok, Binds} -> {ok, Binds, Methods};
        error -> match(Path, Rest)
    end.

bind([], [], Acc) -> {ok, lists:reverse(Acc)};
bind([P | Ps], [S | Ss], Acc) when is_atom(P), S =/= <<>> -> bind(Ps, Ss, [S | Acc]);
bind([S | Ps], [S | Ss], Acc) -> bind(Ps, Ss, Acc);
bind(_, _, _) -> error.

action(A, [Plural | _], [Name]) when A =:= get; A =:= put; A =:= delete ->
    {A, kind(Plural), Name};
action(A, [Plural | _], []) when A =:= list ->
    {A, kind(Plural)};
action(A, _Path, []) -> A;
action(A, _Path, [B]) -> {A, B}.

kind(<<"servers">>) -> server;
kind(<<"devices">>) -> device;
kind(<<"profiles">>) -> profile.

-doc "Whether `Caller` may run a request with `Access` and `Method`.".
-spec check(access(), method(), caller() | {caller(), #{csrf := boolean()}}) ->
          ok | {error, unauthenticated | forbidden | password_change_required | csrf}.
check(Access, Method, {Caller, #{csrf := Csrf}}) ->
    case Csrf orelse Method =:= <<"GET">> orelse Method =:= <<"HEAD">> of
        false -> {error, csrf};
        true -> check(Access, Method, Caller)
    end;
check(public, _Method, _Caller) -> ok;
check(_Access, _Method, anonymous) -> {error, unauthenticated};
check(session, _Method, _Caller) -> ok;
check(_Access, _Method, #{must_change_password := true}) -> {error, password_change_required};
check(viewer, _Method, _Caller) -> ok;
check(admin, _Method, #{role := admin}) -> ok;
check(admin, _Method, _Caller) -> {error, forbidden}.

-doc "HTTP status for an error code of the API.".
-spec status(atom()) -> 400..599.
status(bad_request) -> 400;
status(invalid_json) -> 400;
status(unauthenticated) -> 401;
status(invalid_credentials) -> 401;
status(forbidden) -> 403;
status(csrf) -> 403;
status(password_change_required) -> 403;
status(not_found) -> 404;
status(method_not_allowed) -> 405;
status(no_changes) -> 409;
status(last_admin) -> 409;
status(builtin) -> 409;
status(payload_too_large) -> 413;
status(unsupported_media_type) -> 415;
status(invalid) -> 422;
status(not_running) -> 503;
status(not_registered) -> 503;
status(timeout) -> 504;
status(snmp_error) -> 502;
status(_) -> 500.
