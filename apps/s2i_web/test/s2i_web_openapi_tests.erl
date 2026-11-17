-module(s2i_web_openapi_tests).
-include_lib("eunit/include/eunit.hrl").

%% Every route is documented and every documented operation is routed.
paths_match_routes_test() ->
    Routes = lists:sort([{path(P), M} || {P, Ms} <- s2i_web_rest:routes(), {M, _, _} <- Ms]),
    ?assertEqual(Routes, s2i_web_openapi:operations()).

path(Segments) ->
    iolist_to_binary([[$/, case S of
                               A when is_atom(A) -> [${, atom_to_binary(A), $}];
                               B -> B
                           end] || S <- Segments]).

spec_encodes_as_json_test() ->
    Json = s2i_web_json:encode(s2i_web_openapi:spec()),
    #{<<"openapi">> := <<"3.1.0">>, <<"components">> := #{<<"schemas">> := Schemas}} = json:decode(Json),
    [?assert(is_map_key(S, Schemas)) || S <- [<<"Server">>, <<"Device">>, <<"Profile">>, <<"Error">>]].

refs_resolve_test() ->
    Json = json:decode(s2i_web_json:encode(s2i_web_openapi:spec())),
    #{<<"components">> := #{<<"schemas">> := Schemas}} = Json,
    Refs = refs(Json),
    ?assertNotEqual([], Refs),
    [?assert(is_map_key(R, Schemas), R) || <<"#/components/schemas/", R/binary>> <- Refs].

refs(#{<<"$ref">> := R}) -> [R];
refs(M) when is_map(M) -> lists:append([refs(V) || V <- maps:values(M)]);
refs(L) when is_list(L) -> lists:append([refs(V) || V <- L]);
refs(_) -> [].
