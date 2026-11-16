-module(s2i_live).
-moduledoc """
Live-value table: every configured IEC point with its definition and current
value, `{{Server, Coa, Ioa}, Point, Spec}` where `Point = #{type, source}` and
`Spec` is the erl60870 point map last published (or the invalid seed).

This process only owns the public ETS table; it outlives erl60870 server
restarts, and `s2i_iec_dm` seeds a (re)started server from it. The point set
is maintained by `s2i_iec_mgr`; values are written by `s2i_iec:publish/2`.
""".
-behaviour(gen_server).

-export([start_link/0, child_spec/0]).
-export([points/0, values/1, add/4, remove/2, set/3, get/2]).
-export([init/1, handle_call/3, handle_cast/2]).

-define(TAB, ?MODULE).

-type addr() :: {non_neg_integer(), non_neg_integer()}.

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec child_spec() -> supervisor:child_spec().
child_spec() ->
    #{id => ?MODULE, start => {?MODULE, start_link, []}, type => worker}.

-doc "All points: `#{Server => #{{Coa, Ioa} => #{type, source}}}`.".
-spec points() -> #{binary() => #{addr() => map()}}.
points() ->
    ets:foldl(fun({{S, C, I}, P, _}, Acc) ->
                      maps:update_with(S, fun(Ps) -> Ps#{{C, I} => P} end, #{{C, I} => P}, Acc)
              end, #{}, ?TAB).

-doc "Current values of one server, as `iec60870_server:update/2` writes.".
-spec values(binary()) -> [{addr(), map()}].
values(Server) ->
    [{{C, I}, Spec} || [C, I, Spec] <- ets:match(?TAB, {{Server, '$1', '$2'}, '_', '$3'})].

-spec add(binary(), addr(), map(), map()) -> ok.
add(Server, {C, I}, Point, Spec) ->
    true = ets:insert(?TAB, {{Server, C, I}, Point, Spec}),
    ok.

-spec remove(binary(), addr()) -> ok.
remove(Server, {C, I}) ->
    true = ets:delete(?TAB, {Server, C, I}),
    ok.

-doc "Store a value of a configured point of the same type; `false` otherwise.".
-spec set(binary(), addr(), map()) -> boolean().
set(Server, {C, I}, #{type := Type} = Spec) ->
    Key = {Server, C, I},
    case ets:lookup(?TAB, Key) of
        [{_, #{type := Type}, _}] -> ets:update_element(?TAB, Key, {3, Spec});
        _ -> false
    end.

-spec get(binary(), addr()) -> {ok, map()} | not_found.
get(Server, {C, I}) ->
    case ets:lookup(?TAB, {Server, C, I}) of
        [{_, _, Spec}] -> {ok, Spec};
        [] -> not_found
    end.

%%% gen_server

-spec init([]) -> {ok, #{}}.
init([]) ->
    ?TAB = ets:new(?TAB, [named_table, public, set, {read_concurrency, true},
                          {write_concurrency, true}]),
    {ok, #{}}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, {error, unknown_call}, map()}.
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(_Msg, State) ->
    {noreply, State}.
