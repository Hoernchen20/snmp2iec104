-module(s2i_iec).
-moduledoc "API of the IEC side for the SNMP side.".

-export([publish/2]).

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
            try
                iec60870_server:update(s2i_iec_config:ref(Server), Accepted)
            catch
                error:Reason when Reason =:= unknown_server; Reason =:= server_not_ready -> ok
            end
    end.
