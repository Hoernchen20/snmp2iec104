-module(s2i_reconcile).
-moduledoc """
Pure diffs between desired and running state; the managers only execute them.

- `servers/2`: `#{Name => Spec}` desired vs running → which to stop and which
  to start. A changed spec is a restart (stop + start). All stops come first
  so that a listener port can move between servers in one activation.
- `points/2`: `#{Server => #{Addr => Point}}` old vs new → points to remove and
  to add. A point whose type or source changed is removed and added again:
  its current value does not apply to the new definition.
""".

-export([servers/2, points/2]).

-spec servers(#{Name => Spec}, #{Name => Spec}) -> #{stop := [Name], start := [{Name, Spec}]}
          when Name :: term(), Spec :: term().
servers(Desired, Running) ->
    Stop = [N || N := Spec <- maps:iterator(Running, ordered),
                 maps:get(N, Desired, '$absent') =/= Spec],
    Start = [{N, Spec} || N := Spec <- maps:iterator(Desired, ordered),
                          maps:get(N, Running, '$absent') =/= Spec],
    #{stop => Stop, start => Start}.

-spec points(Points, Points) -> #{remove := [{term(), term()}], add := [{term(), term(), term()}]}
          when Points :: #{term() => #{term() => term()}}.
points(Old, New) ->
    #{remove => [{S, A} || {S, A, P} <- flatten(Old), lookup(S, A, New) =/= {ok, P}],
      add => [{S, A, P} || {S, A, P} <- flatten(New), lookup(S, A, Old) =/= {ok, P}]}.

flatten(Points) ->
    [{S, A, P} || S := Ps <- maps:iterator(Points, ordered), A := P <- maps:iterator(Ps, ordered)].

lookup(S, A, Points) ->
    case Points of
        #{S := #{A := P}} -> {ok, P};
        _ -> error
    end.
