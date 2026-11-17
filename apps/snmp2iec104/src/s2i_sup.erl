-module(s2i_sup).
-moduledoc """
Root supervisor (see docs/DESIGN.md, section 4).

`rest_for_one`: a restart of an earlier child (later: `s2i_config`,
`s2i_routes`) restarts every consumer started after it, so all of them run
against one consistent configuration.
""".
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    Children = [
        s2i_config:child_spec(),
        s2i_iec_sup:child_spec(),
        s2i_snmp_sup:child_spec(),
        s2i_debug_sup:child_spec(),
        s2i_web_sup:child_spec()
    ],
    {ok, {#{strategy => rest_for_one, intensity => 5, period => 10}, Children}}.
