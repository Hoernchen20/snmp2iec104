-module(s2i_iec).
-moduledoc "API of the IEC side for the SNMP side.".

-export([publish/2, invalidate/2, groups/1]).

-doc """
Publish current values of configured points: `[{{Coa, Ioa}, Spec}]` with
`Spec` an erl60870 point map (`type`, `value`, `quality`, `ts`, ...). Values
for points that are not (or no longer) configured with that type are dropped.
The value is stored before it is sent, so a server that is just restarting
still gets it (through `s2i_iec_dm`).
""".
-spec publish(binary(), [{{non_neg_integer(), non_neg_integer()}, map()}]) -> ok.
publish(Server, Writes) ->
    case [W || {Addr, Spec} = W <- Writes, s2i_live:set(Server, Addr, Spec)] of
        [] ->
            ok;
        Accepted ->
            ok = s2i_debug:publish(<<"values:server:", Server/binary>>, #{points => Accepted}),
            try
                iec60870_server:update(s2i_iec_config:ref(Server), Accepted)
            catch
                error:Reason when Reason =:= unknown_server; Reason =:= server_not_ready -> ok
            end
    end.

-doc """
Mark points invalid, keeping their last value (device down, instance no
longer resolvable). Time-tagged points get the time of the invalidation.
Unknown addresses are ignored.
""".
-spec invalidate(binary(), [{non_neg_integer(), non_neg_integer()}]) -> ok.
invalidate(Server, Addrs) ->
    Now = os:system_time(millisecond),
    publish(Server, [{A, invalid(Spec, Now)} || A <- Addrs, {ok, Spec} <- [s2i_live:get(Server, A)]]).

-doc """
Redundancy groups of a running server: `[#{name, active, members,
buffer_len}]` (`name` is `default` for the catch-all group, `active` whether
a connection is the group's active one). `[]` if the server is not running.
Uses erl60870's registry and `iec60870_rgroup:info/1`.
""".
-spec groups(binary()) -> [map()].
groups(Server) ->
    case iec60870_registry:whereis_name({rgroup_sup, s2i_iec_config:name(Server)}) of
        Sup when is_pid(Sup) ->
            Children = try supervisor:which_children(Sup) catch exit:_ -> [] end,
            lists:sort([G || {Id, Pid, _, _} <- Children, is_pid(Pid), {ok, G} <- [group(Id, Pid)]]);
        _ ->
            []
    end.

group(Id, Pid) ->
    try iec60870_rgroup:info(Pid) of
        #{state := State, members := Members, buffer_len := Len} ->
            {ok, #{name => group_name(Id), active => State =/= no_active,
                   members => length(Members), buffer_len => Len}}
    catch
        exit:_ -> error
    end.

group_name(Id) when is_binary(Id); is_atom(Id) -> Id;
group_name(_) -> connection.                    % `connection` mode: one group per connection

invalid(#{ts := _} = Spec, Now) -> Spec#{quality => [invalid], ts := Now};
invalid(Spec, _Now) -> Spec#{quality => [invalid]}.
