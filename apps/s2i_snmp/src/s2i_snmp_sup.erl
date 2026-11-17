-module(s2i_snmp_sup).
-moduledoc """
Root of the SNMP side (`rest_for_one`): the snmpm manager, then the device
processes, then their reconciler, then the MIB library. A manager restart
restarts every device (their registrations are gone); a restart of the
devices supervisor restarts the reconciler, which starts the devices again.
The MIB library (`s2i_mibs`, UI assist only) comes last, so its restart
touches nothing else.
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
          [s2i_snmpm:child_spec(), s2i_devices_sup:child_spec(), s2i_snmp_mgr:child_spec(),
           s2i_mibs:child_spec()]}}.
