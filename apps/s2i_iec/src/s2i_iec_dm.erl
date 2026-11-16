-module(s2i_iec_dm).
-moduledoc """
erl60870 data model: `iec60870_dm_ets`, seeded from `s2i_live` on init. A
server restarted by erl60870 (e.g. after a crash) therefore comes back with
the current values and the invalid seeds instead of an empty point list.
""".
-behaviour(iec60870_data_model).

-export([init/1, terminate/1, read/3, write/4, delete/3, fold/5, coas/1,
         fold_counters/5, freeze_counters/4]).

-spec init(#{server := binary()}) -> {ok, iec60870_dm_ets:state()}.
init(#{server := Server}) ->
    iec60870_dm_ets:init(#{points => s2i_live:values(Server)}).

-spec terminate(iec60870_dm_ets:state()) -> ok.
terminate(St) -> iec60870_dm_ets:terminate(St).

-spec read(iec60870_dm_ets:state(), iec60870_data_model:coa(), non_neg_integer()) ->
          {ok, iec60870_point:point()} | not_found.
read(St, Coa, Ioa) -> iec60870_dm_ets:read(St, Coa, Ioa).

-spec write(iec60870_dm_ets:state(), iec60870_data_model:coa(), non_neg_integer(),
            iec60870_point:point()) -> {ok, iec60870_dm_ets:state(), boolean()}.
write(St, Coa, Ioa, Point) -> iec60870_dm_ets:write(St, Coa, Ioa, Point).

-spec delete(iec60870_dm_ets:state(), iec60870_data_model:coa(), non_neg_integer()) ->
          {ok, iec60870_dm_ets:state()}.
delete(St, Coa, Ioa) -> iec60870_dm_ets:delete(St, Coa, Ioa).

-spec fold(iec60870_dm_ets:state(), iec60870_data_model:coa(), iec60870_data_model:fold_group(),
           fun((non_neg_integer(), iec60870_point:point(), Acc) -> Acc), Acc) -> Acc.
fold(St, Coa, Group, Fun, Acc) -> iec60870_dm_ets:fold(St, Coa, Group, Fun, Acc).

-spec coas(iec60870_dm_ets:state()) -> [iec60870_data_model:coa()].
coas(St) -> iec60870_dm_ets:coas(St).

-spec fold_counters(iec60870_dm_ets:state(), iec60870_data_model:coa(),
                    iec60870_data_model:counter_group(),
                    fun((non_neg_integer(), iec60870_point:point(), Acc) -> Acc), Acc) -> Acc.
fold_counters(St, Coa, Group, Fun, Acc) -> iec60870_dm_ets:fold_counters(St, Coa, Group, Fun, Acc).

-spec freeze_counters(iec60870_dm_ets:state(), iec60870_data_model:coa(),
                      iec60870_data_model:counter_group(), iec60870_data_model:freeze()) ->
          {ok, iec60870_dm_ets:state()}.
freeze_counters(St, Coa, Group, Freeze) -> iec60870_dm_ets:freeze_counters(St, Coa, Group, Freeze).
