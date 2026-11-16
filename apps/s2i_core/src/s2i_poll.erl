-module(s2i_poll).
-moduledoc """
Pure helpers of the poll cycle (used by `s2i_device`):

- `chunks/2`: a poll group's OIDs split by the device's `max_varbinds`.
- `next_deadline/3`: drift-free schedule; a tick that is late by more than
  one interval skips the missed slots (counted as overruns).
- `uptime/2`: reboot detection from `sysUpTime.0`, which every poll group
  carries. Samples are `{Uptime, SentAt}`: requests of different groups can be
  answered out of order, so only a *newer* request reporting a lower uptime
  is a reboot.
- `value/2`: snmpm varbind (no MIB knowledge) → `s2i_transform:snmp_value()`.
- `health/2`: consecutive failed cycles → `up | degraded | down`.
""".

-export([chunks/2, next_deadline/3, uptime/2, value/2, health/2]).

-type sample() :: {Uptime :: non_neg_integer(), SentAt :: integer()}.

-spec chunks([T], pos_integer()) -> [[T]].
chunks([], _Max) ->
    [];
chunks(List, Max) when length(List) =< Max ->
    [List];
chunks(List, Max) ->
    {Chunk, Rest} = lists:split(Max, List),
    [Chunk | chunks(Rest, Max)].

-doc "First slot `Deadline + k*Interval` after `Now` (k >= 1) and the slots skipped.".
-spec next_deadline(integer(), pos_integer(), integer()) -> {integer(), non_neg_integer()}.
next_deadline(Deadline, Interval, Now) ->
    K = max(1, (Now - Deadline) div Interval + 1),
    {Deadline + K * Interval, K - 1}.

-spec uptime(sample() | undefined, sample()) -> {ok | rebooted, sample()}.
uptime(undefined, New) ->
    {ok, New};
uptime({_, SentAt0} = Old, {_, SentAt}) when SentAt =< SentAt0 ->
    {ok, Old};
uptime({Uptime0, _}, {Uptime, _} = New) when Uptime < Uptime0 ->
    {rebooted, New};
uptime(_Old, New) ->
    {ok, New}.

-spec value(atom(), term()) -> s2i_transform:snmp_value().
value('NULL', noSuchObject) -> no_such_object;
value('NULL', noSuchInstance) -> no_such_instance;
value('NULL', endOfMibView) -> end_of_mib_view;
value('NULL', V) -> {null, V};
value(T, V) when T =:= 'INTEGER'; T =:= 'Integer32' -> {integer, V};
value(T, V) when T =:= 'Unsigned32'; T =:= 'Gauge32' -> {gauge32, V};
value('Counter32', V) -> {counter32, V};
value('Counter64', V) -> {counter64, V};
value('TimeTicks', V) -> {timeticks, V};
value(T, V) when T =:= 'OCTET STRING'; T =:= 'IpAddress'; T =:= 'BITS' -> {octet_string, bytes(V)};
value('OBJECT IDENTIFIER', V) -> {oid, V};
value('Opaque', V) -> {opaque, V};
value(T, V) -> {T, V}.

bytes(B) when is_binary(B) -> B;
bytes(L) when is_list(L) -> list_to_binary(L).

-spec health(non_neg_integer(), pos_integer()) -> up | degraded | down.
health(0, _DownAfter) -> up;
health(Failures, DownAfter) when Failures >= DownAfter -> down;
health(_Failures, _DownAfter) -> degraded.
