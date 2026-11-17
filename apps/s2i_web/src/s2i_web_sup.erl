-module(s2i_web_sup).
-moduledoc """
Root of the web side (docs/DESIGN.md §4, §9): the session table and the
cowboy listeners, embedded as ranch children of this supervisor. Routes:
`/api/v1/[...]` (`s2i_web_api`), `/ws` (`s2i_web_ws`), everything else the
built UI (`s2i_web_static`).

Listeners (`s2i_web` env, each optional; port 0 picks a free port):

```erlang
{http,  [{ip, "127.0.0.1"}, {port, 8080}]},
{https, [{ip, "0.0.0.0"}, {port, 8443},
         {certfile, "etc/web.crt"}, {keyfile, "etc/web.key"}]}
```

Before the listeners start, the bootstrap admin is created if there are no
users (`s2i_users:ensure_admin/2`, forced password change): name
`admin_user` (default `admin`), password from the environment variable
`S2I_ADMIN_PASSWORD`, else `admin_password`, else a random one written to
`initial_password_file` (default `data/initial_admin_password`, mode 0600).
""".
-behaviour(supervisor).

-export([start_link/0, child_spec/0, port/1]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec child_spec() -> supervisor:child_spec().
child_spec() ->
    #{id => ?MODULE, start => {?MODULE, start_link, []}, type => supervisor}.

-doc "The bound port of the `http` or `https` listener.".
-spec port(http | https) -> inet:port_number().
port(Kind) ->
    ranch:get_port(ref(Kind)).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    ok = bootstrap_admin(),
    Dispatch = cowboy_router:compile([{'_', [{"/api/v1/[...]", s2i_web_api, #{}},
                                             {"/ws", s2i_web_ws, #{}},
                                             {"/[...]", s2i_web_static, #{}}]}]),
    Proto = #{env => #{dispatch => Dispatch}},
    Listeners = [listener(K, Opts, Proto) || K <- [http, https],
                                             {ok, Opts} <- [application:get_env(s2i_web, K)]],
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10},
          [s2i_web_session:child_spec() | Listeners]}}.

listener(Kind, Opts, Proto) ->
    Socket = [{ip, ip(proplists:get_value(ip, Opts, "127.0.0.1"))},
              {port, proplists:get_value(port, Opts, default_port(Kind))}],
    logger:info("Web ~p listener on ~ts:~p", [Kind, inet:ntoa(proplists:get_value(ip, Socket)),
                                              proplists:get_value(port, Socket)]),
    case Kind of
        http ->
            ranch:child_spec(ref(http), ranch_tcp, #{socket_opts => Socket}, cowboy_clear, Proto);
        https ->
            Tls = [{certfile, proplists:get_value(certfile, Opts)},
                   {keyfile, proplists:get_value(keyfile, Opts)},
                   {versions, ['tlsv1.3', 'tlsv1.2']}]
                ++ [{cacertfile, F} || {cacertfile, F} <- Opts],
            ranch:child_spec(ref(https), ranch_ssl, #{socket_opts => Socket ++ Tls}, cowboy_tls, Proto)
    end.

ref(http) -> s2i_web_http;
ref(https) -> s2i_web_https.

default_port(http) -> 8080;
default_port(https) -> 8443.

ip(Ip) when is_tuple(Ip) -> Ip;
ip(Ip) ->
    {ok, Addr} = inet:parse_address(Ip),
    Addr.

%%% ---------------------------------------------------------------------------

bootstrap_admin() ->
    Name = unicode:characters_to_binary(application:get_env(s2i_web, admin_user, "admin")),
    case mnesia:table_info(s2i_user, size) of
        0 ->
            {Password, Source} = admin_password(),
            case s2i_users:ensure_admin(Name, Password) of
                created ->
                    logger:warning("Created web admin '~ts' with the password from ~ts; it must be "
                                   "changed on first login", [Name, Source]);
                exists ->
                    ok;
                {error, Errors} ->
                    logger:error("Cannot create web admin '~ts' (password from ~ts): ~p",
                                 [Name, Source, Errors]),
                    error({bootstrap_admin, Errors})
            end,
            ok;
        _ ->
            ok
    end.

admin_password() ->
    case os:getenv("S2I_ADMIN_PASSWORD") of
        P when is_list(P), P =/= "" ->
            {unicode:characters_to_binary(P), "S2I_ADMIN_PASSWORD"};
        _ ->
            case application:get_env(s2i_web, admin_password) of
                {ok, P} -> {unicode:characters_to_binary(P), "s2i_web admin_password"};
                undefined -> generated_password()
            end
    end.

generated_password() ->
    File = application:get_env(s2i_web, initial_password_file, "data/initial_admin_password"),
    Password = base64:encode(crypto:strong_rand_bytes(18), #{mode => urlsafe}),
    ok = filelib:ensure_dir(File),
    _ = file:delete(File),
    {ok, Fd} = file:open(File, [write, exclusive, binary]),
    try
        ok = file:change_mode(File, 8#600),
        ok = file:write(Fd, [Password, $\n])
    after
        ok = file:close(Fd)
    end,
    {Password, File}.
