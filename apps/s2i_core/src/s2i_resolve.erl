-module(s2i_resolve).
-moduledoc """
Instance resolution for unstable table indexes (pure).

A resolver column (e.g. IF-MIB `ifName`) is walked on the device; `build/2`
turns the rows into `#{Value => Index}`. Values that occur in more than one
row are **ambiguous** and left out: an instance is never mapped to a guessed
index. Only single-component indexes are supported (rows with compound
indexes are ignored).

`Resolved :: #{Resolver => #{Value => Index}}` is the per-device result used
by `index/2` and `s2i_routes:device/2`.
""".

-export([build/2, index/2, keys/1, columns/2, changed/3]).
-export_type([resolved/0]).

-type oid() :: [non_neg_integer()].
-type resolved() :: #{binary() => #{binary() => non_neg_integer()}}.
-type key() :: {binary(), binary()}.

-doc "Rows of a walk under `Column` → `{#{Value => Index}, AmbiguousValues}`.".
-spec build(oid(), [{oid(), term()}]) -> {#{binary() => non_neg_integer()}, [binary()]}.
build(Column, Rows) ->
    N = length(Column),
    Pairs = [{V, Index}
             || {Oid, Raw} <- Rows,
                lists:prefix(Column, Oid),
                [Index] <- [lists:nthtail(N, Oid)],
                {ok, V} <- [text(Raw)]],
    Counts = lists:foldl(fun({V, _}, Acc) -> maps:update_with(V, fun(C) -> C + 1 end, 1, Acc) end,
                         #{}, Pairs),
    Ambiguous = lists:sort([V || V := C <- Counts, C > 1]),
    {maps:from_list([P || {V, _} = P <- Pairs, maps:get(V, Counts) =:= 1]), Ambiguous}.

text(B) when is_binary(B) -> {ok, B};
text(L) when is_list(L) ->
    try {ok, list_to_binary(L)} catch error:badarg -> error end;
text(_) -> error.

-doc "SNMP table index of a device instance.".
-spec index(map(), resolved()) -> {ok, non_neg_integer()} | unresolved.
index(#{index := Index}, _Resolved) ->
    {ok, Index};
index(#{key := #{resolver := R, value := V}}, Resolved) ->
    case Resolved of
        #{R := #{V := Index}} -> {ok, Index};
        _ -> unresolved
    end.

-doc "Keys a device needs resolved, per resolver (what to walk).".
-spec keys(map()) -> #{binary() => [binary()]}.
keys(#{instances := Instances}) ->
    lists:foldr(fun(#{key := #{resolver := R, value := V}}, Acc) ->
                        maps:update_with(R, fun(Vs) -> [V | Vs] end, [V], Acc);
                   (_, Acc) ->
                        Acc
                end, #{}, Instances).

-doc "Resolver columns (OIDs) a device needs: `#{Resolver => Column}`.".
-spec columns(map(), map()) -> #{binary() => oid()}.
columns(Device, #{resolvers := Resolvers}) ->
    maps:map(fun(R, _Values) ->
                     #{column := Column} = maps:get(R, Resolvers),
                     [binary_to_integer(X) || X <- binary:split(Column, <<".">>, [global])]
             end, keys(Device)).

-doc "Keys whose index differs between two resolutions (only keys in `Keys` count).".
-spec changed(#{binary() => [binary()]}, resolved(), resolved()) -> [key()].
changed(Keys, Old, New) ->
    [{R, V} || R := Vs <- maps:iterator(Keys, ordered), V <- Vs,
               lookup(R, V, Old) =/= lookup(R, V, New)].

lookup(R, V, Resolved) ->
    maps:get(V, maps:get(R, Resolved, #{}), undefined).
