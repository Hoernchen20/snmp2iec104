-module(s2i_iec_callback).
-moduledoc """
erl60870 server callback. Monitoring only: `select/2` / `execute/2` are not
implemented, so erl60870 rejects every command (negative confirmation).
Clock synchronisation is confirmed without touching the system clock (the
library default without `clock_sync/3`). Connection events are logged
and published on the debug topic `iec:<server>` (`#{event => activated |
deactivated | down, conn, reason}`; `conn` is the connection process, as
erl60870 does not report the peer address).
""".
-behaviour(iec60870_server).

-export([init/1, connection_event/2]).

-spec init(#{server := binary()}) -> {ok, #{server := binary()}}.
init(Args) ->
    {ok, Args}.

-spec connection_event(iec60870_server:conn_event(), map()) -> {ok, map()}.
connection_event(Event, #{server := Server} = State) ->
    logger:info("IEC 104 server ~ts: ~p", [Server, Event]),
    ok = s2i_debug:publish(<<"iec:", Server/binary>>, event(Event)),
    {ok, State}.

event({down, Pid, Reason}) -> #{event => down, conn => Pid, reason => Reason};
event({Kind, Pid}) -> #{event => Kind, conn => Pid}.
