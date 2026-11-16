-module(s2i_expand).
-moduledoc """
Profile expansion: device + profile → concrete datapoints and IEC mappings.

```text
IOA = device.ioa_base + instance.slot * profile.ioa_stride + mapping.ioa_offset
      (device-scope datapoints: device.ioa_base + mapping.ioa_offset)
```

A datapoint template is expanded once (`scope => device`) or once per device
instance (`scope => instance`); each mapping template is expanded once per
target binding of its label (unbound label → no mapping). Device overrides
disable datapoints (all or some slots) or patch single mappings.

Datapoint:

```erlang
#{id         => <<"sw-a/if3/operStatus">>,    %% device name / name template with slot
  template   => <<"if{slot}/operStatus">>,
  slot       => 3,                            %% instance scope only
  oid        => [1,3,6,1,2,1,2,2,1,8,10101]   %% concrete, or
              | {key, Prefix, {Resolver, Value}},  %% index resolved at runtime
  poll_group => <<"status">>,                 %% optional (trap-only otherwise)
  mappings   => [#{server, coa, ioa, type, transform, deadband => _}]}
```

`config/1` expands all devices of a validated configuration and checks that
every `(server, coa, ioa)` is used once and fits the server's `ioa_size`.
Everything here is pure.
""".

-export([device/2, config/1]).
-export_type([expansion/0, datapoint/0, mapping/0]).

-type mapping() :: #{server := binary(), coa := pos_integer(), ioa := non_neg_integer(),
                     type := atom(), transform := map(), deadband => map()}.
-type oid() :: [non_neg_integer()].
-type datapoint() :: #{id := binary(), template := binary(), slot => non_neg_integer(),
                       oid := oid() | {key, oid(), {binary(), binary()}},
                       poll_group => binary(), mappings := [mapping()]}.
-type expansion() :: #{name := binary(), datapoints := [datapoint()],
                       comm_status => #{server := binary(), coa := pos_integer(),
                                        ioa := pos_integer(), type := atom()}}.

%%% ===========================================================================
%%% One device
%%% ===========================================================================

-doc "Expand one (canonical) device with its profile. Error paths are relative to the device.".
-spec device(map(), map()) -> {ok, expansion()} | {error, [s2i_schema:error()]}.
device(#{name := Name} = Device, #{datapoints := Templates} = Profile) ->
    case override_errors(Device, Templates) of
        [] ->
            Dps = lists:flatmap(fun(T) -> expand_template(T, Device, Profile) end, Templates),
            Exp = #{name => Name, datapoints => Dps},
            {ok, case Device of
                     #{comm_status := Cs} -> Exp#{comm_status => Cs};
                     _ -> Exp
                 end};
        Errors ->
            {error, [#{path => P, error => E} || {P, E} <- Errors]}
    end.

expand_template(#{scope := device} = T, Device, Profile) ->
    datapoint(T, undefined, Device, Profile);
expand_template(#{scope := instance} = T, #{instances := Instances} = Device, Profile) ->
    lists:flatmap(fun(I) -> datapoint(T, I, Device, Profile) end, Instances).

datapoint(#{name := TName, oid := OidT, mappings := MTs} = T, Instance, Device, Profile) ->
    #{name := DevName, ioa_base := Base, targets := Targets, overrides := Overrides} = Device,
    Slot = case Instance of
               undefined -> undefined;
               #{slot := S} -> S
           end,
    case override_for(TName, Slot, Overrides) of
        #{enabled := false} ->
            [];
        Override ->
            Patches = maps:get(mappings, Override, []),
            SlotBase = case Slot of
                           undefined -> Base;
                           _ -> Base + Slot * maps:get(ioa_stride, Profile)
                       end,
            Mappings = [mapping(M, Binding, SlotBase)
                        || {J, MT} <- enumerate(MTs),
                           M <- patched(MT, patch_for(J, Patches)),
                           Binding <- maps:get(maps:get(target, M), Targets, [])],
            Dp0 = #{id => dp_id(DevName, TName, Slot), template => TName,
                    oid => oid(OidT, Instance), mappings => Mappings},
            Dp1 = case Slot of
                      undefined -> Dp0;
                      _ -> Dp0#{slot => Slot}
                  end,
            [case T of
                 #{poll_group := G} -> Dp1#{poll_group => G};
                 _ -> Dp1
             end]
    end.

mapping(#{ioa_offset := Off, type := Type, transform := Tr} = M, #{server := S, coa := C}, Base) ->
    Out = #{server => S, coa => C, ioa => Base + Off, type => Type, transform => Tr},
    case M of
        #{deadband := D} -> Out#{deadband => D};
        _ -> Out
    end.

patched(MT, undefined) -> [MT];
patched(_MT, #{enabled := false}) -> [];
patched(MT, Patch) -> [merge_patch(MT, Patch)].

merge_patch(MT, Patch) ->
    maps:merge(MT, maps:with([type, transform, deadband], Patch)).

dp_id(Dev, TName, undefined) ->
    <<Dev/binary, "/", TName/binary>>;
dp_id(Dev, TName, Slot) ->
    <<Dev/binary, "/", (binary:replace(TName, <<"{slot}">>, integer_to_binary(Slot), [global]))/binary>>.

oid(OidT, undefined) ->
    oid_ints(OidT);
oid(OidT, Instance) ->
    Prefix = oid_ints(binary:part(OidT, 0, byte_size(OidT) - byte_size(<<".{index}">>))),
    case Instance of
        #{index := Index} -> Prefix ++ [Index];
        #{key := #{resolver := R, value := V}} -> {key, Prefix, {R, V}}
    end.

oid_ints(B) ->
    [binary_to_integer(X) || X <- binary:split(B, <<".">>, [global])].

%%% ---------------------------------------------------------------------------
%%% Overrides
%%% ---------------------------------------------------------------------------

%% An override matches a datapoint by template name and (if given) slot.
override_for(TName, Slot, Overrides) ->
    case [O || #{datapoint := D} = O <- Overrides, D =:= TName,
               Slot =:= undefined orelse not is_map_key(slots, O)
                   orelse lists:member(Slot, maps:get(slots, O))] of
        [O | _] -> O;
        [] -> #{}
    end.

patch_for(J, Patches) ->
    case [P || #{index := I} = P <- Patches, I =:= J] of
        [P] -> P;
        [] -> undefined
    end.

override_errors(#{overrides := Overrides, instances := Instances}, Templates) ->
    Slots = [S || #{slot := S} <- Instances],
    ByName = maps:from_list([{N, T} || #{name := N} = T <- Templates]),
    {Errors, _Covered} =
        lists:foldl(
          fun({I, O}, {Errs, Covered}) ->
                  P = [overrides, I],
                  case maps:find(maps:get(datapoint, O), ByName) of
                      error ->
                          {Errs ++ [{P ++ [datapoint], unknown_datapoint}], Covered};
                      {ok, T} ->
                          case override_target_errors(P, O, T, Slots) of
                              [] ->
                                  Keys = [{maps:get(datapoint, O), S} || S <- covered_slots(O, T, Slots)],
                                  Dup = [{P, duplicate} || lists:any(fun(K) -> sets:is_element(K, Covered) end, Keys)],
                                  {Errs ++ Dup, sets:union(Covered, sets:from_list(Keys, [{version, 2}]))};
                              Es ->
                                  {Errs ++ Es, Covered}
                          end
                  end
          end, {[], sets:new([{version, 2}])}, enumerate(Overrides)),
    Errors.

override_target_errors(P, O, #{scope := Scope, mappings := MTs}, Slots) ->
    SlotErrors =
        case {Scope, O} of
            {device, #{slots := _}} ->
                [{P ++ [slots], not_allowed_for_device_scope}];
            {instance, #{slots := OSlots}} ->
                [{P ++ [slots, K], unknown_slot}
                 || {K, S} <- enumerate(OSlots), not lists:member(S, Slots)];
            _ ->
                []
        end,
    MappingErrors =
        lists:append(
          [case Index < length(MTs) of
               false ->
                   [{P ++ [mappings, K, index], unknown_mapping}];
               true ->
                   Merged = merge_patch(lists:nth(Index + 1, MTs), Patch),
                   [{P ++ [mappings, K | Rel], E} || {Rel, E} <- s2i_schema:mapping_errors(Merged)]
           end
           || {K, #{index := Index} = Patch} <- enumerate(maps:get(mappings, O))]),
    SlotErrors ++ MappingErrors.

covered_slots(_O, #{scope := device}, _Slots) -> [device];
covered_slots(#{slots := S}, _T, _Slots) -> S;
covered_slots(_O, _T, Slots) -> Slots.

%%% ===========================================================================
%%% Whole configuration
%%% ===========================================================================

-doc """
Expand all devices of a reference-checked configuration and check IEC
addresses: `ioa_collision` (reported on the later mapping, devices in name
order, with `detail => #{server, coa, ioa, with => EarlierPath}`) and
`out_of_range` (IOA 0 or beyond the server's `ioa_size`).
""".
-spec config(s2i_validate:config()) ->
          {ok, #{binary() => expansion()}} | {error, [s2i_schema:error()]}.
config(#{devices := Devices, profiles := Profiles, servers := Servers}) ->
    Results = [{Name, device(D, maps:get(Profile, Profiles))}
               || Name := #{profile := Profile} = D <- maps:iterator(Devices, ordered)],
    case [E#{path := [devices, Name | P]} || {Name, {error, Es}} <- Results, #{path := P} = E <- Es] of
        [] ->
            Expansions = [{Name, Exp} || {Name, {ok, Exp}} <- Results],
            case address_errors(Expansions, Servers) of
                [] -> {ok, maps:from_list(Expansions)};
                Errors -> {error, Errors}
            end;
        Errors ->
            {error, Errors}
    end.

address_errors(Expansions, Servers) ->
    Addresses = lists:append([addresses(Name, Exp) || {Name, Exp} <- Expansions]),
    {Errors, _} =
        lists:foldl(
          fun({Path, #{server := S, coa := C, ioa := Ioa}}, {Errs, Seen}) ->
                  Key = {S, C, Ioa},
                  Detail = #{server => S, coa => C, ioa => Ioa},
                  case {in_range(S, Ioa, Servers), maps:find(Key, Seen)} of
                      {false, _} ->
                          {[#{path => Path, error => out_of_range, detail => Detail} | Errs], Seen};
                      {true, {ok, First}} ->
                          {[#{path => Path, error => ioa_collision, detail => Detail#{with => First}} | Errs],
                           Seen};
                      {true, error} ->
                          {Errs, Seen#{Key => Path}}
                  end
          end, {[], #{}}, Addresses),
    lists:reverse(Errors).

addresses(Name, #{datapoints := Dps} = Exp) ->
    [{[devices, Name, datapoints, Id, mappings, J], M}
     || #{id := Id, mappings := Ms} <- Dps, {J, M} <- enumerate(Ms)] ++
    [{[devices, Name, comm_status], Cs} || #{comm_status := Cs} <- [Exp]].

in_range(Server, Ioa, Servers) ->
    case Servers of
        #{Server := #{params := #{ioa_size := Size}}} -> Ioa >= 1 andalso Ioa < (1 bsl (8 * Size));
        _ -> Ioa >= 1
    end.

enumerate(List) ->
    lists:zip(lists:seq(0, length(List) - 1), List).
