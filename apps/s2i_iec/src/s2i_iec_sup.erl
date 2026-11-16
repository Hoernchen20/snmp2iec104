-module(s2i_iec_sup).
-moduledoc "Root of the IEC 104 side; will host s2i_iec_mgr (phase 3).".
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
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, []}}.
