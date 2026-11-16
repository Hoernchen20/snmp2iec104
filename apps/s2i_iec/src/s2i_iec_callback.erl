-module(s2i_iec_callback).
-moduledoc """
erl60870 server callback. Monitoring only: `select/2` / `execute/2` are not
implemented, so erl60870 rejects every command (negative confirmation).
Clock synchronisation is confirmed without touching the system clock (the
library default without `clock_sync/3`). Connection events are logged
(debug UI topics follow in phase 7).
""".
-behaviour(iec60870_server).

-export([init/1, connection_event/2]).

-spec init(#{server := binary()}) -> {ok, #{server := binary()}}.
init(Args) ->
    {ok, Args}.

-spec connection_event(iec60870_server:conn_event(), map()) -> {ok, map()}.
connection_event(Event, #{server := Server} = State) ->
    logger:info("IEC 104 server ~ts: ~p", [Server, Event]),
    {ok, State}.
