-module(snmp2iec104_app).
-moduledoc "Gateway application entry point.".
-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> supervisor:startlink_ret().
start(_StartType, _Args) ->
    s2i_sup:start_link().

-spec stop(term()) -> ok.
stop(_State) ->
    ok.
