-module(s2i_web_static).
-moduledoc """
Serves the built web UI (docs/DESIGN.md §2: React + Vite, built into
`priv/www` of this app, or `s2i_web` `www_dir`).

- `GET`/`HEAD` only. Files below the directory are sent as they are;
  `assets/` (content-hashed names from Vite) with a one-year immutable cache,
  everything else `no-cache`.
- Other paths without a file extension get `index.html` (client-side
  routes such as `/devices/sw1`); a missing file with an extension is 404.
- Without a build, a short plain-text hint instead of the UI.
- Security headers on every response (CSP: same origin only, plus inline
  styles; no framing).
""".
-behaviour(cowboy_handler).

-export([init/2]).

-define(CSP, <<"default-src 'self'; connect-src 'self'; img-src 'self' data:; "
               "style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; "
               "form-action 'self'">>).

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, Opts) ->
    Req = case cowboy_req:method(Req0) of
              M when M =:= <<"GET">>; M =:= <<"HEAD">> ->
                  serve(cowboy_req:path_info(Req0), Req0);
              _ ->
                  cowboy_req:reply(405, (headers())#{<<"allow">> => <<"GET, HEAD">>}, Req0)
          end,
    {ok, Req, Opts}.

serve(Segs, Req) ->
    Dir = www_dir(),
    case safe(Segs) of
        false ->
            not_found(Req);
        true ->
            Path = filename:join([Dir | Segs]),
            case Segs =/= [] andalso filelib:is_regular(Path) of
                true ->
                    send(Path, cache(Segs), Req);
                false ->
                    case Segs =/= [] andalso filename:extension(lists:last(Segs)) =/= <<>> of
                        true -> not_found(Req);
                        false -> index(Dir, Req)
                    end
            end
    end.

index(Dir, Req) ->
    Index = filename:join(Dir, "index.html"),
    case filelib:is_regular(Index) of
        true ->
            send(Index, <<"no-cache">>, Req);
        false ->
            cowboy_req:reply(404, (headers())#{<<"content-type">> => <<"text/plain; charset=utf-8">>},
                             <<"The web UI is not built. Run `npm ci && npm run build` in frontend/ "
                               "(or set s2i_web www_dir). The REST API is at /api/v1.\n">>, Req)
    end.

send(Path, Cache, Req) ->
    Size = filelib:file_size(Path),
    cowboy_req:reply(200, (headers())#{<<"content-type">> => mime(Path), <<"cache-control">> => Cache},
                     {sendfile, 0, Size, Path}, Req).

not_found(Req) ->
    cowboy_req:reply(404, (headers())#{<<"content-type">> => <<"text/plain; charset=utf-8">>},
                     <<"not found\n">>, Req).

%% No `..`, no absolute or hidden segments (cowboy has already split on `/`).
safe(Segs) ->
    lists:all(fun(S) -> S =/= <<>> andalso binary:first(S) =/= $. andalso
                            binary:match(S, [<<"/">>, <<"\\">>, <<0>>]) =:= nomatch
              end, Segs).

cache([<<"assets">> | _]) -> <<"public, max-age=31536000, immutable">>;
cache(_) -> <<"no-cache">>.

mime(Path) ->
    case cow_mimetypes:all(unicode:characters_to_binary(Path)) of
        {T, S, _} when T =:= <<"text">>; S =:= <<"javascript">>; S =:= <<"json">> ->
            <<T/binary, "/", S/binary, "; charset=utf-8">>;
        {T, S, _} ->
            <<T/binary, "/", S/binary>>
    end.

headers() ->
    #{<<"content-security-policy">> => ?CSP,
      <<"x-content-type-options">> => <<"nosniff">>,
      <<"x-frame-options">> => <<"DENY">>,
      <<"referrer-policy">> => <<"same-origin">>}.

www_dir() ->
    case application:get_env(s2i_web, www_dir) of
        {ok, Dir} -> Dir;
        undefined -> filename:join(code:priv_dir(s2i_web), "www")
    end.
