-module(s2i_debug_ring).
-moduledoc "Bounded FIFO (ring buffer) for the debug history: the newest `Max` items.".

-export([new/1, push/2, to_list/1, size/1]).
-export_type([ring/0]).

-opaque ring() :: {Max :: pos_integer(), Len :: non_neg_integer(), queue:queue()}.

-spec new(pos_integer()) -> ring().
new(Max) when is_integer(Max), Max > 0 ->
    {Max, 0, queue:new()}.

-doc "Append `Item`; drops the oldest item when full.".
-spec push(term(), ring()) -> ring().
push(Item, {Max, Max, Q}) ->
    {Max, Max, queue:in(Item, queue:drop(Q))};
push(Item, {Max, Len, Q}) ->
    {Max, Len + 1, queue:in(Item, Q)}.

-doc "Items, oldest first.".
-spec to_list(ring()) -> list().
to_list({_, _, Q}) ->
    queue:to_list(Q).

-spec size(ring()) -> non_neg_integer().
size({_, Len, _}) ->
    Len.
