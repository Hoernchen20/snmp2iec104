-module(s2i_debug_log).
-moduledoc """
`logger` handler feeding the debug topic `log` (installed by `s2i_debug`).
Runs in the logging process: formats the message into one line (at most
`?MAX_CHARS` characters) and casts it to `s2i_debug`.
""".

-export([log/2, event/1]).

-define(MAX_CHARS, 4096).

-spec log(logger:log_event(), logger:handler_config()) -> ok.
log(Event, _Config) ->
    s2i_debug:publish(<<"log">>, event(Event)).

-doc "The debug event of a log event: `#{at, level, msg, mfa, pid}`.".
-spec event(logger:log_event()) -> map().
event(#{level := Level, meta := Meta} = Event) ->
    Msg = logger_formatter:format(Event, #{single_line => true, template => [msg],
                                           chars_limit => ?MAX_CHARS}),
    At = case Meta of
             #{time := T} -> T div 1000;
             _ -> os:system_time(millisecond)
         end,
    maps:merge(#{at => At, level => Level, msg => unicode:characters_to_binary(Msg)},
               maps:from_list([{mfa, mfa(MFA)} || #{mfa := MFA} <- [Meta]]
                              ++ [{pid, list_to_binary(pid_to_list(P))} || #{pid := P} <- [Meta], is_pid(P)])).

mfa({M, F, A}) when is_atom(M), is_atom(F), is_integer(A) ->
    iolist_to_binary(io_lib:format("~ts:~ts/~b", [M, F, A]));
mfa(Other) ->
    iolist_to_binary(io_lib:format("~0p", [Other])).
