-module(s2i_routes).
-moduledoc """
Route compiler (pure): expansion + resolved indexes → runtime lookup tables.

`device/2` produces, for one device:

- `routes`: `#{Oid => [Route]}` with
  `Route = #{datapoint, server, coa, ioa, type, transform, deadband => _}`.
  Used for poll responses and trap varbind matching alike.
- `polls`: `#{PollGroup => [Oid]}` (sorted, unique), every group with
  `sysUpTime.0` for reboot detection; datapoints without mappings or with an
  unresolved instance are not polled.
- `unresolved`: datapoints whose instance key is not resolved; their mappings
  are published with quality `invalid` until resolution succeeds.
- `slots`: `#{Index => Slot}` to map trap varbinds (e.g. ifIndex) to slots.
- `comm_status`: the device's comm-status point, if configured.

`points/1` lists every IEC address per server (resolved or not, plus comm
status) for seeding and for adding/removing points on reconfiguration.
""".

-export([device/2, points/1, sys_uptime/0]).
-export_type([device_routes/0, route/0]).

-define(SYS_UPTIME, [1, 3, 6, 1, 2, 1, 1, 3, 0]).

-type oid() :: [non_neg_integer()].
-type route() :: #{datapoint := binary(), server := binary(), coa := pos_integer(),
                   ioa := non_neg_integer(), type := atom(), transform := map(),
                   deadband => map()}.
-type device_routes() :: #{routes := #{oid() => [route()]},
                           polls := #{binary() => [oid()]},
                           unresolved := [s2i_expand:datapoint()],
                           slots := #{non_neg_integer() => non_neg_integer()},
                           comm_status => map()}.

-spec sys_uptime() -> oid().
sys_uptime() -> ?SYS_UPTIME.

-spec device(s2i_expand:expansion(), s2i_resolve:resolved()) -> device_routes().
device(#{datapoints := Dps} = Exp, Resolved) ->
    {Concrete, Unresolved} =
        lists:foldr(
          fun(Dp, {C, U}) ->
                  case concrete_oid(Dp, Resolved) of
                      {ok, Oid, Slot} -> {[{Oid, Slot, Dp} | C], U};
                      unresolved -> {C, [Dp | U]}
                  end
          end, {[], []}, Dps),
    Routes = lists:foldr(
               fun({Oid, _, #{id := Id, mappings := Ms}}, Acc) when Ms =/= [] ->
                       Rs = [M#{datapoint => Id} || M <- Ms],
                       maps:update_with(Oid, fun(Old) -> Rs ++ Old end, Rs, Acc);
                  (_, Acc) ->
                       Acc
               end, #{}, Concrete),
    Polls = maps:map(
              fun(_G, Oids) -> lists:usort([?SYS_UPTIME | Oids]) end,
              lists:foldl(
                fun({Oid, _, #{poll_group := G, mappings := [_ | _]}}, Acc) ->
                        maps:update_with(G, fun(Os) -> [Oid | Os] end, [Oid], Acc);
                   (_, Acc) ->
                        Acc
                end, #{}, Concrete)),
    Slots = maps:from_list([{lists:last(Oid), Slot} || {Oid, Slot, _} <- Concrete, Slot =/= undefined]),
    Out = #{routes => Routes, polls => Polls, unresolved => Unresolved, slots => Slots},
    case Exp of
        #{comm_status := Cs} -> Out#{comm_status => Cs};
        _ -> Out
    end.

concrete_oid(#{oid := {key, Prefix, {R, V}}, slot := Slot}, Resolved) ->
    case s2i_resolve:index(#{slot => Slot, key => #{resolver => R, value => V}}, Resolved) of
        {ok, Index} -> {ok, Prefix ++ [Index], Slot};
        unresolved -> unresolved
    end;
concrete_oid(#{oid := Oid} = Dp, _Resolved) ->
    {ok, Oid, maps:get(slot, Dp, undefined)}.

-doc "`#{Server => #{{Coa, Ioa} => #{type, source}}}` over all devices.".
-spec points(#{binary() => s2i_expand:expansion()}) ->
          #{binary() => #{{pos_integer(), non_neg_integer()} => map()}}.
points(Expansions) ->
    maps:fold(
      fun(Dev, Exp, Acc0) ->
              Acc1 = lists:foldl(
                       fun(#{id := Id, mappings := Ms}, A) ->
                               lists:foldl(
                                 fun(#{server := S, coa := C, ioa := I, type := T}, A2) ->
                                         add_point(S, {C, I}, #{type => T, source => {datapoint, Id}}, A2)
                                 end, A, Ms)
                       end, Acc0, maps:get(datapoints, Exp)),
              case Exp of
                  #{comm_status := #{server := S, coa := C, ioa := I, type := T}} ->
                      add_point(S, {C, I}, #{type => T, source => {comm_status, Dev}}, Acc1);
                  _ ->
                      Acc1
              end
      end, #{}, Expansions).

add_point(Server, Addr, Point, Acc) ->
    maps:update_with(Server, fun(Ps) -> Ps#{Addr => Point} end, #{Addr => Point}, Acc).
