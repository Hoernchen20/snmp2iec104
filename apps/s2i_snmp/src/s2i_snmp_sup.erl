-module(s2i_snmp_sup).
-moduledoc "Root of the SNMP side; will host s2i_snmpm_user and s2i_devices_sup (phase 4).".
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
    {ok, {#{strategy => rest_for_one, intensity => 5, period => 10}, []}}.
