-module(s2i_devices_sup).
-moduledoc """
Supervisor of the `s2i_device` processes, one child per device (id = device
name), added and removed by `s2i_snmp_mgr`. Generous restart intensity: a
device that keeps crashing must not take the others down quickly.

Owns the `s2i_trap_sources` table, which lives as long as the devices.
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
    ok = s2i_trap_sources:new(),
    {ok, {#{strategy => one_for_one, intensity => 50, period => 60}, []}}.
