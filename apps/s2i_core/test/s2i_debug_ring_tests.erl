-module(s2i_debug_ring_tests).
-include_lib("eunit/include/eunit.hrl").

empty_test() ->
    R = s2i_debug_ring:new(3),
    ?assertEqual([], s2i_debug_ring:to_list(R)),
    ?assertEqual(0, s2i_debug_ring:size(R)).

keeps_order_test() ->
    R = lists:foldl(fun s2i_debug_ring:push/2, s2i_debug_ring:new(3), [a, b]),
    ?assertEqual([a, b], s2i_debug_ring:to_list(R)).

drops_oldest_test() ->
    R = lists:foldl(fun s2i_debug_ring:push/2, s2i_debug_ring:new(3), [a, b, c, d, e]),
    ?assertEqual([c, d, e], s2i_debug_ring:to_list(R)),
    ?assertEqual(3, s2i_debug_ring:size(R)).

bounded_prop_test() ->
    %% never more than Max, always the newest Max items in order
    lists:foreach(
      fun({Max, N}) ->
              Items = lists:seq(1, N),
              R = lists:foldl(fun s2i_debug_ring:push/2, s2i_debug_ring:new(Max), Items),
              ?assertEqual(lists:nthtail(max(0, N - Max), Items), s2i_debug_ring:to_list(R))
      end, [{M, N} || M <- [1, 2, 5], N <- lists:seq(0, 12)]).
