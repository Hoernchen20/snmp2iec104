-module(s2i_debug_sup).
-moduledoc "The debug topics: the `pg` scope and `s2i_debug` (ring buffers, log handler).".
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
    Children = [#{id => pg, start => {pg, start_link, [s2i_debug:scope()]}},
                #{id => s2i_debug, start => {s2i_debug, start_link, []}}],
    {ok, {#{strategy => one_for_all, intensity => 5, period => 10}, Children}}.
