-module(s2i_iec_sup).
-moduledoc """
Root of the IEC 104 side, `rest_for_one`: `s2i_live` (live-value table) is
started first; if it is lost, the manager restarts and re-seeds everything.
The erl60870 servers themselves run under erl60870's own supervisor.
""".
-behaviour(supervisor).

-export([start_link/0, child_spec/0]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec child_spec() -> supervisor:child_spec().
child_spec() ->
    #{id => ?MODULE, start => {?MODULE, start_link, []}, type => supervisor}.

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    {ok, {#{strategy => rest_for_one, intensity => 5, period => 10},
          [s2i_live:child_spec(), s2i_iec_mgr:child_spec()]}}.
