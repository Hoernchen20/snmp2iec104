-module(s2i_trap_sources).
-moduledoc """
Source IP → device process, for traps and informs that do not come from the
address a device is polled on (agents often send from another port), so
snmpm passes them to the default user (`s2i_snmpm_user:handle_agent/5`).

A public ETS bag owned by `s2i_devices_sup` (created in its `init/1`): it
lives exactly as long as the device processes that fill it. A device adds
its IP when registered and removes it when deregistered; entries of dead
processes are ignored on lookup.
""".

-export([new/0, add/1, remove/1, lookup/1]).

-define(TAB, ?MODULE).

-spec new() -> ok.
new() ->
    ?TAB = ets:new(?TAB, [bag, public, named_table, {read_concurrency, true}]),
    ok.

-spec add(inet:ip_address()) -> ok.
add(Ip) ->
    true = ets:insert(?TAB, {Ip, self()}),
    ok.

-spec remove(inet:ip_address()) -> ok.
remove(Ip) ->
    _ = catch ets:delete_object(?TAB, {Ip, self()}),
    ok.

-doc "The live device processes registered for `Ip`.".
-spec lookup(inet:ip_address()) -> [pid()].
lookup(Ip) ->
    try ets:lookup(?TAB, Ip) of
        Entries -> [Pid || {_, Pid} <- Entries, is_process_alive(Pid)]
    catch
        error:badarg -> []
    end.
