-module(s2i_debug_SUITE).
-moduledoc "s2i_debug: pg topics, ring-buffer history, logger handler.".

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([unbuffered_topic_goes_to_subscribers_only/1,
         buffered_topic_keeps_history/1,
         history_is_bounded/1,
         subscribe_twice_delivers_once/1,
         unsubscribe_stops_delivery/1,
         publish_without_debug_running/1,
         log_topic_gets_logger_events/1]).

all() ->
    [unbuffered_topic_goes_to_subscribers_only,
     buffered_topic_keeps_history,
     history_is_bounded,
     subscribe_twice_delivers_once,
     unsubscribe_stops_delivery,
     publish_without_debug_running,
     log_topic_gets_logger_events].

init_per_testcase(publish_without_debug_running, Config) ->
    Config;
init_per_testcase(_TC, Config) ->
    ok = application:set_env(s2i_core, debug_history, 3),
    {ok, Sup} = s2i_debug_sup:start_link(),
    unlink(Sup),
    [{sup, Sup} | Config].

end_per_testcase(_TC, Config) ->
    case ?config(sup, Config) of
        undefined -> ok;
        Sup -> ok = gen_server:stop(Sup)
    end,
    ok = application:unset_env(s2i_core, debug_history),
    ok.

%%% cases

unbuffered_topic_goes_to_subscribers_only(_Config) ->
    T = <<"values:device:d1">>,
    ?assertNot(s2i_debug:active(T)),
    ok = s2i_debug:publish(T, #{n => 0}),           % nobody listens: dropped
    {ok, []} = s2i_debug:subscribe(T),
    ?assert(s2i_debug:active(T)),
    ok = s2i_debug:publish(T, #{n => 1}),
    receive {s2i_debug, T, #{n := 1, at := At}} -> ?assert(is_integer(At)) after 1000 -> error(no_event) end,
    %% no history for unbuffered topics
    Self = self(),
    Pid = spawn_link(fun() -> Self ! {history, s2i_debug:subscribe(T)} end),
    receive {history, {ok, []}} -> ok after 1000 -> error({no_history, Pid}) end,
    flush().

buffered_topic_keeps_history(_Config) ->
    ok = s2i_debug:publish(<<"traps">>, #{n => 1, at => 5}),
    ok = s2i_debug:publish(<<"iec:s1">>, #{n => 2}),
    {ok, [#{n := 1, at := 5}]} = s2i_debug:subscribe(<<"traps">>),
    ok = s2i_debug:publish(<<"traps">>, #{n => 3}),
    receive {s2i_debug, <<"traps">>, #{n := 3}} -> ok after 1000 -> error(no_event) end,
    {ok, [#{n := 2}]} = s2i_debug:subscribe(<<"iec:s1">>),
    {ok, []} = s2i_debug:subscribe(<<"iec:s2">>).

history_is_bounded(_Config) ->
    [ok = s2i_debug:publish(<<"traps">>, #{n => N}) || N <- lists:seq(1, 5)],
    {ok, H} = s2i_debug:subscribe(<<"traps">>),
    ?assertEqual([3, 4, 5], [N || #{n := N} <- H]).

subscribe_twice_delivers_once(_Config) ->
    T = <<"snmp:trace:d1">>,
    {ok, _} = s2i_debug:subscribe(T),
    {ok, _} = s2i_debug:subscribe(T),
    ok = s2i_debug:publish(T, #{n => 1}),
    receive {s2i_debug, T, _} -> ok after 1000 -> error(no_event) end,
    receive {s2i_debug, T, _} = Dup -> error({duplicate, Dup}) after 100 -> ok end.

unsubscribe_stops_delivery(_Config) ->
    T = <<"values:server:s1">>,
    {ok, _} = s2i_debug:subscribe(T),
    ok = s2i_debug:unsubscribe(T),
    ok = s2i_debug:unsubscribe(T),
    ?assertNot(s2i_debug:active(T)),
    ok = s2i_debug:publish(T, #{n => 1}),
    receive {s2i_debug, T, _} = M -> error({unexpected, M}) after 100 -> ok end.

publish_without_debug_running(_Config) ->
    ?assertEqual(undefined, whereis(s2i_debug)),
    ?assertNot(s2i_debug:active(<<"values:device:d1">>)),
    ok = s2i_debug:publish(<<"values:device:d1">>, #{}),
    ok = s2i_debug:publish(<<"traps">>, #{}).

log_topic_gets_logger_events(_Config) ->
    {ok, _} = s2i_debug:subscribe(<<"log">>),
    logger:notice("debug suite ~p", [hello], #{mfa => {?MODULE, log_topic_gets_logger_events, 1}}),
    logger:debug("below the handler level"),
    Ev = receive_log(<<"debug suite hello">>),
    ?assertMatch(#{level := notice, mfa := <<"s2i_debug_SUITE:log_topic_gets_logger_events/1">>,
                   pid := <<"<", _/binary>>, at := _}, Ev),
    %% the handler goes away with s2i_debug
    ?assert(lists:member(s2i_debug, logger:get_handler_ids())).

receive_log(Msg) ->
    receive
        {s2i_debug, <<"log">>, #{msg := Msg} = Ev} -> Ev;
        {s2i_debug, <<"log">>, #{level := debug} = Ev} -> error({below_level, Ev});
        {s2i_debug, <<"log">>, _} -> receive_log(Msg)
    after 1000 ->
            error(no_log_event)
    end.

flush() ->
    receive _ -> flush() after 0 -> ok end.
