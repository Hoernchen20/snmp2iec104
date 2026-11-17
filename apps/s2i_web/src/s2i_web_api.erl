-module(s2i_web_api).
-moduledoc """
Cowboy handler for `/api/v1/[...]` (docs/DESIGN.md §9.1, §9.2).

Per request: route and access (`s2i_web_rest`), caller from the session
cookie (`s2i_web_session`, user and role from `s2i_users`), CSRF header,
JSON body (at most `?MAX_BODY`), then the action. Responses are JSON;
errors are `{"error": Code, "errors": [SchemaError]}` with the HTTP status
from `s2i_web_rest:status/1`.

Secrets: entities are returned in their stored form, so SNMP secrets only
ever appear as `enc:v1:` envelopes (ciphertext). Sending an envelope back
unchanged keeps the secret.
""".
-behaviour(cowboy_handler).

-export([init/2]).
-export([cookie_name/0]).

-define(COOKIE, <<"s2i_session">>).
-define(MAX_BODY, 8 * 1024 * 1024).
-define(AUDIT_DEFAULT, 100).
-define(AUDIT_MAX, 10000).
-define(WALK_DEFAULT, 1000).
-define(WALK_MAX, 10000).

-spec cookie_name() -> binary().
cookie_name() -> ?COOKIE.

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, Opts) ->
    Req = try
              handle(Req0)
          catch
              throw:{reply, Status, Body, R} ->
                  reply(Status, Body, R);
              Class:Reason:Stack ->
                  logger:error("REST ~ts ~ts crashed: ~p:~p ~p",
                               [cowboy_req:method(Req0), cowboy_req:path(Req0), Class, Reason, Stack]),
                  error_reply(internal_error, [], Req0)
          end,
    {ok, Req, Opts}.

handle(Req0) ->
    Method = cowboy_req:method(Req0),
    case s2i_web_rest:route(Method, cowboy_req:path_info(Req0)) of
        {error, not_found} ->
            error_reply(not_found, [], Req0);
        {error, {method_not_allowed, Allowed}} ->
            Req = cowboy_req:set_resp_header(<<"allow">>, lists:join(<<", ">>, Allowed), Req0),
            error_reply(method_not_allowed, [], Req);
        {ok, Action, Access} ->
            {Token, User} = caller(Req0),
            Csrf = cowboy_req:header(<<"x-requested-with">>, Req0, <<>>) =/= <<>>,
            case s2i_web_rest:check(Access, Method, {caller_access(User), #{csrf => Csrf}}) of
                ok ->
                    {Body, Req} = body(Req0),
                    Ctx = #{req => Req, user => User, token => Token, body => Body},
                    respond(action(Action, Ctx), Req);
                {error, Code} ->
                    error_reply(Code, [], Req0)
            end
    end.

caller(Req) ->
    Cookies = cowboy_req:parse_cookies(Req),
    case lists:keyfind(?COOKIE, 1, Cookies) of
        {_, Token} ->
            case s2i_web_session:lookup(Token) of
                {ok, Name} ->
                    case s2i_users:get(Name) of
                        {ok, User} -> {Token, User};
                        {error, not_found} -> {Token, anonymous}
                    end;
                error ->
                    {undefined, anonymous}
            end;
        false ->
            {undefined, anonymous}
    end.

caller_access(anonymous) -> anonymous;
caller_access(User) -> maps:with([role, must_change_password], User).

body(Req0) ->
    case cowboy_req:has_body(Req0) of
        false ->
            {undefined, Req0};
        true ->
            case cowboy_req:read_body(Req0, #{length => ?MAX_BODY, period => 15000}) of
                {ok, <<>>, Req} ->
                    {undefined, Req};
                {ok, Data, Req} ->
                    try
                        {json:decode(Data), Req}
                    catch
                        error:_ -> throw_error(invalid_json, Req)
                    end;
                {more, _, Req} ->
                    throw_error(payload_too_large, Req)
            end
    end.

respond({error, Code}, Req) -> error_reply(Code, [], Req);
respond({error, Code, Errors}, Req) -> error_reply(Code, Errors, Req);
respond({Status, Body}, Req) when is_integer(Status) -> reply(Status, Body, Req);
respond({Status, Body, Req1}, _Req) when is_integer(Status) -> reply(Status, Body, Req1).

reply(204, _Body, Req) ->
    cowboy_req:reply(204, headers(), Req);
reply(Status, Body, Req) ->
    cowboy_req:reply(Status, (headers())#{<<"content-type">> => <<"application/json">>},
                     s2i_web_json:encode(Body), Req).

headers() ->
    #{<<"cache-control">> => <<"no-store">>, <<"x-content-type-options">> => <<"nosniff">>}.

error_reply(Code, Errors, Req) ->
    Body = case Errors of
               [] -> #{error => Code};
               _ -> #{error => Code, errors => Errors}
           end,
    reply(s2i_web_rest:status(Code), Body, Req).

-spec throw_error(atom(), cowboy_req:req()) -> no_return().
throw_error(Code, Req) ->
    throw({reply, s2i_web_rest:status(Code), #{error => Code}, Req}).

%%% ===========================================================================
%%% Actions
%%% ===========================================================================

%% --- session ----------------------------------------------------------------

action(login, #{body := #{<<"username">> := Name, <<"password">> := Pw}, req := Req}) ->
    case s2i_users:authenticate(Name, Pw) of
        {ok, User} ->
            Token = s2i_web_session:create(Name),
            logger:notice("Web login of ~ts from ~ts", [Name, peer(Req)]),
            {200, me(User), set_cookie(Token, Req)};
        {error, invalid_credentials} ->
            logger:notice("Failed web login for ~0p from ~ts", [Name, peer(Req)]),
            {error, invalid_credentials}
    end;
action(login, _Ctx) ->
    bad_request([username, password]);
action(logout, #{token := Token, req := Req}) ->
    ok = s2i_web_session:delete(Token),
    {204, none, clear_cookie(Req)};
action(me, #{user := User}) ->
    {200, me(User)};
action(change_password, #{user := #{name := Name}, token := Token,
                          body := #{<<"current_password">> := Cur, <<"new_password">> := New}}) ->
    case s2i_users:change_password(Name, Cur, New) of
        ok ->
            ok = s2i_web_session:delete_user(Name, Token),
            {ok, User} = s2i_users:get(Name),
            {200, me(User)};
        {error, invalid_credentials} ->
            {error, invalid_credentials};
        {error, Errors} ->
            {error, invalid, Errors}
    end;
action(change_password, _Ctx) ->
    bad_request([current_password, new_password]);
action(openapi, _Ctx) ->
    {200, s2i_web_openapi:spec()};

%% --- staged entities ---------------------------------------------------------

action({list, Kind}, _Ctx) ->
    {200, s2i_config:list(Kind)};
action({get, Kind, Name}, _Ctx) ->
    case s2i_config:get(Kind, Name) of
        {ok, E} -> {200, E};
        {error, not_found} -> {error, not_found}
    end;
action({put, Kind, Name}, #{body := Body} = Ctx) when is_map(Body) ->
    case maps:get(<<"name">>, Body, Name) of
        Name ->
            case s2i_config:put(Kind, Body#{<<"name">> => Name}, actor(Ctx)) of
                {ok, E} -> {200, E};
                {error, Errors} -> {error, invalid, Errors}
            end;
        _ ->
            {error, invalid, [#{path => [name], error => name_mismatch}]}
    end;
action({put, _Kind, _Name}, _Ctx) ->
    {error, bad_request};
action({delete, Kind, Name}, Ctx) ->
    case s2i_config:delete(Kind, Name, actor(Ctx)) of
        ok -> {204, none};
        {error, not_found} -> {error, not_found}
    end;

%% --- users -------------------------------------------------------------------

action(user_list, _Ctx) ->
    {200, s2i_users:list()};
action({user_get, Name}, _Ctx) ->
    case s2i_users:get(Name) of
        {ok, U} -> {200, U};
        Error -> Error
    end;
action({user_put, Name}, #{body := Body, token := Token} = Ctx) when is_map(Body) ->
    case s2i_users:put(Name, Body, actor(Ctx)) of
        {ok, U} ->
            _ = is_map_key(<<"password">>, Body) andalso end_sessions(Name, Ctx, Token),
            {200, U};
        {error, Errors} ->
            {error, invalid, Errors}
    end;
action({user_put, _Name}, _Ctx) ->
    {error, bad_request};
action({user_delete, Name}, Ctx) ->
    case s2i_users:delete(Name, actor(Ctx)) of
        ok ->
            ok = s2i_web_session:delete_user(Name),
            {204, none};
        Error ->
            Error
    end;

%% --- configuration -----------------------------------------------------------

action(staged, _Ctx) ->
    {200, #{config => s2i_config:staged(), has_changes => s2i_config:has_changes()}};
action(active, _Ctx) ->
    case s2i_config:active() of
        {ok, Vsn, Config} -> {200, #{vsn => Vsn, config => Config}};
        {error, none} -> {error, not_found}
    end;
action(validate, _Ctx) ->
    Restarts = server_restarts(),
    case s2i_config:validate() of
        ok -> {200, #{valid => true, has_changes => s2i_config:has_changes(), server_restarts => Restarts}};
        {error, Errors} -> {200, #{valid => false, errors => Errors, server_restarts => Restarts}}
    end;
action(activate, #{body := Body} = Ctx) ->
    case comment(Body) of
        {ok, Comment} ->
            case s2i_config:activate(actor(Ctx), Comment) of
                {ok, Vsn} -> {200, #{vsn => Vsn}};
                {error, no_changes} -> {error, no_changes};
                {error, Errors} -> {error, invalid, Errors}
            end;
        error ->
            {error, invalid, [#{path => [comment], error => invalid_type}]}
    end;
action(revert, Ctx) ->
    ok = s2i_config:revert(actor(Ctx)),
    {204, none};
action(export, #{req := Req}) ->
    case qs(<<"source">>, Req, <<"staged">>) of
        S when S =:= <<"staged">>; S =:= <<"active">> ->
            case s2i_config:export(binary_to_existing_atom(S)) of
                {ok, Config} -> {200, Config};
                {error, none} -> {error, not_found}
            end;
        _ ->
            {error, bad_request}
    end;
action(import, #{body := Body} = Ctx) when is_map(Body) ->
    case s2i_config:import(Body, actor(Ctx)) of
        ok -> {204, none};
        {error, Errors} -> {error, invalid, Errors}
    end;
action(import, _Ctx) ->
    {error, bad_request};
action(audit, #{req := Req}) ->
    case int(qs(<<"limit">>, Req, integer_to_binary(?AUDIT_DEFAULT))) of
        {ok, N} when N >= 0, N =< ?AUDIT_MAX -> {200, s2i_config:audit(N)};
        _ -> {error, bad_request}
    end;
action(versions, _Ctx) ->
    {200, s2i_config:versions()};
action({version, V}, _Ctx) ->
    case int(V) of
        {ok, Vsn} ->
            case s2i_config:version(Vsn) of
                {ok, Config} -> {200, #{vsn => Vsn, config => Config}};
                Error -> Error
            end;
        error ->
            {error, not_found}
    end;
action({restore, V}, Ctx) ->
    case int(V) of
        {ok, Vsn} ->
            case s2i_config:restore(Vsn, actor(Ctx)) of
                ok -> {204, none};
                Error -> Error
            end;
        error ->
            {error, not_found}
    end;

%% --- status ------------------------------------------------------------------

action(status, _Ctx) ->
    {200, #{devices => device_status(), servers => server_status(),
            active_vsn => active_vsn(), has_changes => s2i_config:has_changes()}};
action(device_status_list, _Ctx) ->
    {200, device_status()};
action({device_status, Name}, _Ctx) ->
    case [S || #{name := N} = S <- device_status(), N =:= Name] of
        [S] -> {200, S};
        [] -> {error, not_found}
    end;
action(server_status_list, _Ctx) ->
    {200, server_status()};

%% --- tools -------------------------------------------------------------------

action(snmp_get, #{body := #{<<"device">> := Device, <<"oids">> := Oids}}) when is_list(Oids), Oids =/= [] ->
    case oids(Oids) of
        {ok, Parsed} -> snmp_result(s2i_device:get(Device, Parsed));
        {error, Errors} -> {error, invalid, Errors}
    end;
action(snmp_get, _Ctx) ->
    bad_request([device, oids]);
action(snmp_walk, #{body := #{<<"device">> := Device, <<"oid">> := Oid} = Body}) ->
    Max = maps:get(<<"max">>, Body, ?WALK_DEFAULT),
    case {s2i_web_json:parse_oid(Oid), is_integer(Max) andalso Max >= 1 andalso Max =< ?WALK_MAX} of
        {{ok, Root}, true} -> snmp_result(s2i_device:walk(Device, Root, Max));
        {error, _} -> {error, invalid, [#{path => [oid], error => invalid_format}]};
        {_, false} -> {error, invalid, [#{path => [max], error => out_of_range}]}
    end;
action(snmp_walk, _Ctx) ->
    bad_request([device, oid]).

%%% ===========================================================================
%%% Helpers
%%% ===========================================================================

me(User) ->
    maps:with([name, role, must_change_password], User).

actor(#{user := #{name := Name}}) -> Name.

bad_request(Fields) ->
    {error, bad_request, [#{path => [F], error => required} || F <- Fields]}.

end_sessions(Name, #{user := #{name := Name}}, Token) ->
    s2i_web_session:delete_user(Name, Token);
end_sessions(Name, _Ctx, _Token) ->
    s2i_web_session:delete_user(Name).

comment(undefined) -> {ok, <<>>};
comment(#{<<"comment">> := C}) when is_binary(C) -> {ok, C};
comment(#{<<"comment">> := _}) -> error;
comment(#{}) -> {ok, <<>>};
comment(_) -> error.

qs(Key, Req, Default) ->
    case lists:keyfind(Key, 1, cowboy_req:parse_qs(Req)) of
        {_, V} when is_binary(V) -> V;
        _ -> Default
    end.

int(B) ->
    try {ok, binary_to_integer(B)} catch error:badarg -> error end.

oids(Oids) ->
    Parsed = [{I, s2i_web_json:parse_oid(O)} || {I, O} <- lists:enumerate(0, Oids)],
    case [#{path => [oids, I], error => invalid_format} || {I, error} <- Parsed] of
        [] -> {ok, [O || {_, {ok, O}} <- Parsed]};
        Errors -> {error, Errors}
    end.

snmp_result({ok, Vbs}) ->
    {200, #{varbinds => [s2i_web_json:varbind(V) || V <- Vbs]}};
snmp_result({ok, Vbs, Completion}) ->
    {200, #{varbinds => [s2i_web_json:varbind(V) || V <- Vbs], truncated => Completion =:= truncated}};
snmp_result({error, Code}) when Code =:= not_running; Code =:= not_registered; Code =:= timeout ->
    {error, Code};
snmp_result({error, too_many_oids}) ->
    {error, invalid, [#{path => [oids], error => too_many_oids}]};
snmp_result({error, Reason}) ->
    {error, snmp_error, [#{path => [], error => snmp_error, detail => #{reason => Reason}}]}.

active_vsn() ->
    case s2i_config:active() of
        {ok, Vsn, _} -> Vsn;
        {error, none} -> null
    end.

%% IEC servers whose restart activating the staged configuration would cause.
server_restarts() ->
    Old = case s2i_config:active() of
              {ok, _, #{servers := S}} -> S;
              {error, none} -> #{}
          end,
    s2i_iec_config:restarts(Old, maps:get(servers, s2i_config:staged())).

device_status() ->
    Devices = case s2i_config:active() of
                  {ok, _, #{devices := Ds}} -> Ds;
                  {error, none} -> #{}
              end,
    [maps:merge(#{name => Name, enabled => Enabled}, running_status(Name, Enabled))
     || Name := #{enabled := Enabled} <- maps:iterator(Devices, ordered)].

running_status(_Name, false) ->
    #{health => disabled};
running_status(Name, true) ->
    try s2i_device:status(Name) of
        {ok, S} -> S;
        {error, not_running} -> #{health => not_running}
    catch
        exit:_ -> #{health => not_running}
    end.

server_status() ->
    Servers = case s2i_config:active() of
                  {ok, _, #{servers := S}} -> S;
                  {error, none} -> #{}
              end,
    Running = try s2i_iec_mgr:status() catch exit:_ -> #{} end,
    Points = s2i_live:points(),
    [#{name => Name, state => maps:get(Name, Running, not_running),
       points => map_size(maps:get(Name, Points, #{}))}
     || Name := _ <- maps:iterator(Servers, ordered)].

set_cookie(Token, Req) ->
    cowboy_req:set_resp_cookie(?COOKIE, Token, Req,
                               #{http_only => true, same_site => strict, path => <<"/">>,
                                 secure => cowboy_req:scheme(Req) =:= <<"https">>}).

clear_cookie(Req) ->
    cowboy_req:set_resp_cookie(?COOKIE, <<>>, Req,
                               #{http_only => true, same_site => strict, path => <<"/">>, max_age => 0,
                                 secure => cowboy_req:scheme(Req) =:= <<"https">>}).

peer(Req) ->
    {Ip, _Port} = cowboy_req:peer(Req),
    inet:ntoa(Ip).
