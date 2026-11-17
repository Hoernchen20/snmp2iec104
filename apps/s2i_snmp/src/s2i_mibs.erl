-module(s2i_mibs).
-moduledoc """
MIB library (docs/DESIGN.md §13): uploaded MIB modules, compiled with
`snmpc`, and the name index built from them and from the MIBs that ship with
OTP. UI assist only (OID ↔ name, OID browser, enum labels, notification
names); the runtime works on numeric OIDs and never waits for this server.

- Sources are stored in the Mnesia table `s2i_mib`
  (`{s2i_mib, Name, SchemaVsn, Map}`, not part of config versions or
  exports); uploads and deletes go into the audit log.
- Compiled modules are cached in `mib_dir` (default `<dir>/mibs` of
  `s2i_snmp`): `Name.mib`, `Name.bin` and `Name.meta` (cache key and
  result, so neither good nor failing modules are compiled again while
  their source and imports are unchanged, see `s2i_mib_src:cache_key/3`).
- A module whose imports are missing or failed is not compiled; uploading
  the missing module later compiles its dependents. A compile failure only
  affects that module and its dependents.
- The index is published in `persistent_term` (it changes only on uploads
  and deletes), so lookups run in the caller and never block on a compile.
""".
-behaviour(gen_server).

%% OTP's snmp records have untyped fields
-compile(nowarn_untyped_record).
-include_lib("snmp/include/snmp_types.hrl").

-export([start_link/0, child_spec/0]).
-export([list/0, get/1, source/1, put/2, delete/2]).
-export([lookup/1, translate/1, resolve/1, children/1, search/2]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export_type([info/0]).

-define(TAB, s2i_mib).
-define(SCHEMA_VSN, 1).
-define(PT, {?MODULE, index}).
-define(OPTS_VSN, 1).
-define(COMPILE_TIMEOUT, 60000).
-define(CALL_TIMEOUT, 600000).
%% built into snmpc: importable, but there is no .bin
-define(SMI, [<<"SNMPv2-SMI">>, <<"SNMPv2-TC">>, <<"SNMPv2-CONF">>,
              <<"RFC1155-SMI">>, <<"RFC-1212">>, <<"RFC-1215">>]).
%% shipped with OTP but not indexed: OTP's own and the v1 variant of SNMPv2-MIB
-define(NOT_INDEXED, [<<"OTP-REG">>, <<"OTP-TC">>, <<"OTP-SNMPEA-MIB">>, <<"STANDARD-MIB">>]).

-type name() :: binary().
-type info() :: #{name := name(), origin := builtin | uploaded,
                  status := ok | pending | error | missing_imports | dependency_failed,
                  objects := non_neg_integer(), _ => _}.

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec child_spec() -> supervisor:child_spec().
child_spec() ->
    #{id => ?MODULE, start => {?MODULE, start_link, []}, type => worker}.

%%% ===========================================================================
%%% Modules
%%% ===========================================================================

-doc "All modules (built-in and uploaded) by name.".
-spec list() -> [info()].
list() ->
    case index() of
        #{modules := Ms} -> [I || _ := I <- maps:iterator(Ms, ordered)];
        undefined -> []
    end.

-spec get(name()) -> {ok, info()} | {error, not_found}.
get(Name) ->
    case index() of
        #{modules := #{Name := I}} -> {ok, I};
        _ -> {error, not_found}
    end.

-doc "The source of a module; for built-in modules the one shipped with OTP.".
-spec source(name()) -> {ok, binary()} | {error, not_found}.
source(Name) when is_binary(Name) ->
    case mnesia:dirty_read(?TAB, Name) of
        [{_, _, _, #{source := Source}}] ->
            {ok, Source};
        [] ->
            case s2i_mib_src:valid_name(Name) andalso lists:member(Name, otp_names()) of
                true ->
                    case file:read_file(filename:join([code:lib_dir(snmp), "mibs", <<Name/binary, ".mib">>])) of
                        {ok, Source} -> {ok, Source};
                        {error, _} -> {error, not_found}
                    end;
                false ->
                    {error, not_found}
            end
    end.

-doc """
Store the modules in `Sources` (each a MIB file with one or more modules,
replacing modules of the same name) and compile. Modules named like a
built-in one are skipped.
""".
-spec put([binary()], binary()) ->
          {ok, #{modules := [info()], skipped := [name()]}} | {error, [map()]}.
put(Sources, Actor) ->
    gen_server:call(?MODULE, {put, Sources, Actor}, ?CALL_TIMEOUT).

-spec delete(name(), binary()) -> ok | {error, not_found | builtin}.
delete(Name, Actor) ->
    gen_server:call(?MODULE, {delete, Name, Actor}, ?CALL_TIMEOUT).

%%% ===========================================================================
%%% Index (runs in the caller)
%%% ===========================================================================

-spec lookup([non_neg_integer()]) -> {ok, s2i_mib_index:def()} | error.
lookup(Oid) ->
    with_tables(fun(T) -> s2i_mib_index:lookup(T, Oid) end, error).

-spec translate([non_neg_integer()]) -> {ok, s2i_mib_index:def(), [non_neg_integer()]} | error.
translate(Oid) ->
    with_tables(fun(T) -> s2i_mib_index:translate(T, Oid) end, error).

-spec resolve(binary()) ->
          {ok, [non_neg_integer()]} | {error, invalid | not_found | {ambiguous, [binary()]}}.
resolve(Text) ->
    with_tables(fun(T) -> s2i_mib_index:resolve(T, Text) end, {error, not_found}).

-spec children([non_neg_integer()]) -> [{[non_neg_integer()], s2i_mib_index:def() | undefined, boolean()}].
children(Oid) ->
    with_tables(fun(T) -> s2i_mib_index:children(T, Oid) end, []).

-spec search(binary(), pos_integer()) -> [s2i_mib_index:def()].
search(Query, Limit) ->
    with_tables(fun(T) -> s2i_mib_index:search(T, Query, Limit) end, []).

index() ->
    persistent_term:get(?PT, undefined).

%% The tables of a replaced index are deleted right after the swap: retry once
%% with the new ones.
with_tables(Fun, Default) ->
    with_tables(Fun, Default, 2).

with_tables(_Fun, Default, 0) ->
    Default;
with_tables(Fun, Default, N) ->
    case index() of
        #{tables := T} ->
            try Fun(T) catch error:badarg -> with_tables(Fun, Default, N - 1) end;
        undefined ->
            Default
    end.

%%% ===========================================================================
%%% gen_server
%%% ===========================================================================

-spec init([]) -> {ok, map(), {continue, compile}}.
init([]) ->
    process_flag(trap_exit, true),
    Dir = dir(),
    ok = filelib:ensure_path(Dir),
    Builtin = builtin(),
    Known = ?SMI ++ otp_names(),
    State = #{dir => Dir, builtin => Builtin, known => Known, tables => undefined},
    %% the built-in MIBs right away; uploaded ones once compiled
    Pending = #{N => (info(M))#{status => pending, objects => 0} || N := M <- stored()},
    {ok, publish(State, [], Pending), {continue, compile}}.

-spec handle_continue(compile, map()) -> {noreply, map()}.
handle_continue(compile, State) ->
    {noreply, rebuild(State)}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call({put, Sources, Actor}, _From, State) ->
    case parse(Sources) of
        {ok, Modules} ->
            {Skipped, New} = lists:partition(fun(#{name := N}) -> known(N, State) end, Modules),
            Now = erlang:system_time(millisecond),
            ok = transaction(
                   fun() ->
                           lists:foreach(
                             fun(#{name := N, imports := Imports, source := Src}) ->
                                     ok = mnesia:write({?TAB, N, ?SCHEMA_VSN,
                                                        #{name => N, source => Src, imports => Imports,
                                                          size => byte_size(Src),
                                                          uploaded_at => Now, uploaded_by => Actor}}),
                                     audit(Actor, mib_put, N, Now)
                             end, New)
                   end),
            Names = [N || #{name := N} <- New],
            _ = [logger:notice("MIB ~ts uploaded by ~ts", [N, Actor]) || N <- Names],
            State1 = rebuild(State),
            #{modules := Infos} = index(),
            {reply, {ok, #{modules => [maps:get(N, Infos) || N <- Names],
                           skipped => [N || #{name := N} <- Skipped]}}, State1};
        {error, Errors} ->
            {reply, {error, Errors}, State}
    end;
handle_call({delete, Name, Actor}, _From, #{dir := Dir} = State) ->
    case known(Name, State) of
        true ->
            {reply, {error, builtin}, State};
        false ->
            Now = erlang:system_time(millisecond),
            Result = transaction(fun() ->
                                         case mnesia:read(?TAB, Name, write) of
                                             [] -> {error, not_found};
                                             [_] ->
                                                 ok = mnesia:delete({?TAB, Name}),
                                                 audit(Actor, mib_delete, Name, Now)
                                         end
                                 end),
            case Result of
                ok ->
                    logger:notice("MIB ~ts deleted by ~ts", [Name, Actor]),
                    ok = remove_files(Dir, Name),
                    {reply, ok, rebuild(State)};
                Error ->
                    {reply, Error, State}
            end
    end;
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), map()) -> ok.
terminate(_Reason, _State) ->
    _ = persistent_term:erase(?PT),
    ok.

%%% ===========================================================================
%%% Compile and index
%%% ===========================================================================

-spec dir() -> file:filename().
dir() ->
    case application:get_env(s2i_snmp, mib_dir) of
        {ok, D} when D =/= undefined -> D;
        _ -> filename:join(application:get_env(s2i_snmp, dir, "data/snmp"), "mibs")
    end.

parse(Sources) when is_list(Sources), Sources =/= [] ->
    Results = [{I, split(S)} || {I, S} <- lists:enumerate(0, Sources)],
    case [E#{path => [sources, I]} || {I, {error, E}} <- Results] of
        [] ->
            Modules = lists:append([Ms || {_, {ok, Ms}} <- Results]),
            Names = [N || #{name := N} <- Modules],
            case Names -- lists:usort(Names) of
                [] -> {ok, Modules};
                Dups -> {error, [#{path => [sources], error => duplicate_module,
                                   detail => #{modules => lists:usort(Dups)}}]}
            end;
        Errors ->
            {error, Errors}
    end;
parse(_) ->
    {error, [#{path => [sources], error => required}]}.

split(Source) when is_binary(Source) ->
    case s2i_mib_src:split(Source) of
        {ok, Ms} -> {ok, Ms};
        {error, no_module} -> {error, #{error => no_module}};
        {error, {Code, Name}} -> {error, #{error => Code, detail => #{module => Name}}}
    end;
split(_) ->
    {error, #{error => invalid_type}}.

stored() ->
    maps:from_list([{N, M} || {_, N, _, M} <- mnesia:dirty_select(?TAB, [{'_', [], ['$_']}])]).

%% Compile every uploaded module (cached where unchanged), then publish a new
%% index of the compiled and the built-in modules.
rebuild(#{dir := Dir} = State) ->
    Stored = stored(),
    ok = cleanup(Dir, Stored),
    {Order, Blocked} = s2i_mib_src:order(#{N => Is || N := #{imports := Is} <- Stored},
                                         fun(N) -> known(N, State) end),
    Vsn = compiler_vsn(),
    Results0 = #{N => B || N := B <- Blocked},
    {Results, _Keys} =
        lists:foldl(
          fun(Name, {Rs, Keys}) ->
                  #{source := Src, imports := Imports} = maps:get(Name, Stored),
                  Deps = [D || D <- Imports, is_map_key(D, Stored), D =/= Name],
                  case [D || D <- Deps, maps:get(D, Rs) =/= ok] of
                      [] ->
                          Key = s2i_mib_src:cache_key(Vsn, Src, [{D, maps:get(D, Keys)} || D <- Deps]),
                          {Rs#{Name => compile_cached(Dir, Name, Src, Key)}, Keys#{Name => Key}};
                      Failed ->
                          ok = remove_bin(Dir, Name),
                          {Rs#{Name => {dependency, Failed}}, Keys}
                  end
          end, {Results0, #{}}, Order),
    _ = [ok = remove_bin(Dir, N) || N := R <- Results, R =/= ok],
    Uploaded = [{N, Defs} || N := ok <- maps:iterator(Results, ordered),
                             {ok, Defs} <- [read_defs(N, bin_path(Dir, N))]],
    Infos = #{N => uploaded_info(maps:get(N, Stored), R, Uploaded) || N := R <- Results},
    publish(State, Uploaded, Infos).

publish(#{builtin := Builtin, tables := Old} = State, Uploaded, UploadedInfos) ->
    Defs = lists:append([D || {_, D} <- Uploaded])
           ++ lists:append([D || {_, D} <- Builtin])
           ++ s2i_mib_index:smi_defs(),
    Tables = s2i_mib_index:build(Defs),
    BuiltinInfos = #{N => #{name => N, origin => builtin, status => ok, objects => length(D)}
                     || {N, D} <- Builtin},
    persistent_term:put(?PT, #{tables => Tables, modules => maps:merge(BuiltinInfos, UploadedInfos)}),
    _ = Old =/= undefined andalso s2i_mib_index:delete(Old),
    State#{tables := Tables}.

info(#{name := N, imports := Is, size := Size, uploaded_at := At, uploaded_by := By}) ->
    #{name => N, origin => uploaded, imports => Is, size => Size, uploaded_at => At, uploaded_by => By}.

uploaded_info(Stored, Result, Uploaded) ->
    I = info(Stored),
    case Result of
        ok ->
            {_, Defs} = lists:keyfind(maps:get(name, I), 1, Uploaded),
            I#{status => ok, objects => length(Defs)};
        {error, Messages} -> I#{status => error, objects => 0, messages => Messages};
        {missing, Ms} -> I#{status => missing_imports, objects => 0, missing => Ms};
        {dependency, Ds} -> I#{status => dependency_failed, objects => 0, dependencies => Ds}
    end.

read_defs(Name, Path) ->
    case snmp_misc:read_mib(Path) of
        {ok, #mib{} = Mib} ->
            {ok, s2i_mib_index:defs(Name, Mib)};
        Error ->
            logger:warning("Cannot read compiled MIB ~ts: ~p", [Path, Error]),
            error
    end.

%% RFC1213-MIB (SMIv1) last: where it overlaps SNMPv2-MIB, the SMIv2 module names the OID
builtin() ->
    Names = otp_names() -- ?NOT_INDEXED,
    [{N, Defs} || N <- (Names -- [<<"RFC1213-MIB">>]) ++ [<<"RFC1213-MIB">> || lists:member(<<"RFC1213-MIB">>, Names)],
                  {ok, Defs} <- [read_defs(N, filename:join(otp_mib_dir(), <<N/binary, ".bin">>))]].

otp_mib_dir() ->
    filename:join(code:priv_dir(snmp), "mibs").

otp_names() ->
    lists:sort([list_to_binary(filename:basename(F, ".bin"))
                || F <- filelib:wildcard(filename:join(otp_mib_dir(), "*.bin"))]).

known(Name, #{known := Known}) ->
    lists:member(Name, Known).

compiler_vsn() ->
    {ok, Vsn} = application:get_key(snmp, vsn),
    term_to_binary({Vsn, ?OPTS_VSN}).

bin_path(Dir, Name) -> filename:join(Dir, <<Name/binary, ".bin">>).
meta_path(Dir, Name) -> filename:join(Dir, <<Name/binary, ".meta">>).
src_path(Dir, Name) -> filename:join(Dir, <<Name/binary, ".mib">>).

compile_cached(Dir, Name, Source, Key) ->
    case cached(Dir, Name, Key) of
        {ok, Result} ->
            Result;
        miss ->
            Result = compile(Dir, Name, Source),
            ok = file:write_file(meta_path(Dir, Name), term_to_binary({Key, Result})),
            Result
    end.

cached(Dir, Name, Key) ->
    case file:read_file(meta_path(Dir, Name)) of
        {ok, Bin} ->
            try binary_to_term(Bin, [safe]) of
                {Key, ok} ->
                    case filelib:is_regular(bin_path(Dir, Name)) of
                        true -> {ok, ok};
                        false -> miss
                    end;
                {Key, {error, _} = E} -> {ok, E};
                _ -> miss
            catch
                error:badarg -> miss
            end;
        {error, _} ->
            miss
    end.

compile(Dir, Name, Source) ->
    ok = file:write_file(src_path(Dir, Name), Source),
    ok = remove_bin(Dir, Name),
    D = unicode:characters_to_list(Dir) ++ "/",
    Opts = [{outdir, D}, {i, [D]}, {il, ["snmp/priv/mibs/"]},
            {group_check, false}, {deprecated, true}, {description, true},
            {warnings, false}, {verbosity, silence}, relaxed_row_name_assign_check],
    File = unicode:characters_to_list(filename:rootname(src_path(Dir, Name))),
    case capture(fun() -> snmpc:compile(File, Opts) end, ?COMPILE_TIMEOUT) of
        {{ok, _}, _Output} ->
            ok;
        {{error, Reason}, Output} ->
            case messages(Output) of
                [] -> {error, [#{message => iolist_to_binary(io_lib:format("~0p", [Reason]))}]};
                Ms -> {error, Ms}
            end;
        {timeout, _} ->
            {error, [#{message => <<"compilation timed out">>}]};
        {{crash, Reason}, Output} ->
            {error, messages(Output) ++ [#{message => iolist_to_binary(io_lib:format("compiler crashed: ~0p", [Reason]))}]}
    end.

%% snmpc prints its errors (`File.mib: Line: Message`): run it with a group
%% leader that collects them.
capture(Fun, Timeout) ->
    Leader = spawn(fun() -> collect([]) end),
    Self = self(),
    Tag = make_ref(),
    {Pid, Ref} = spawn_monitor(fun() -> group_leader(Leader, self()), Self ! {Tag, Fun()} end),
    Result = receive
                 {Tag, R} -> erlang:demonitor(Ref, [flush]), R;
                 {'DOWN', Ref, process, Pid, Reason} -> {crash, Reason}
             after Timeout ->
                 exit(Pid, kill),
                 receive {'DOWN', Ref, process, Pid, _} -> timeout end
             end,
    Leader ! {output, self()},
    receive
        {output, Leader, Output} -> {Result, Output}
    after 5000 ->
        {Result, <<>>}
    end.

collect(Acc) ->
    receive
        {io_request, From, ReplyAs, Req} ->
            {Reply, Acc1} = io_request(Req, Acc),
            From ! {io_reply, ReplyAs, Reply},
            collect(Acc1);
        {output, Pid} ->
            Pid ! {output, self(), iolist_to_binary(lists:reverse(Acc))}
    end.

io_request({put_chars, Enc, Chars}, Acc) ->
    {ok, [chars(Enc, Chars) | Acc]};
io_request({put_chars, Enc, M, F, A}, Acc) ->
    {ok, [chars(Enc, apply(M, F, A)) | Acc]};
io_request({put_chars, Chars}, Acc) ->
    {ok, [chars(latin1, Chars) | Acc]};
io_request({requests, Reqs}, Acc) ->
    {ok, lists:foldl(fun(R, A) -> element(2, io_request(R, A)) end, Acc, Reqs)};
io_request(_Other, Acc) ->
    {{error, enotsup}, Acc}.

chars(Enc, Chars) ->
    case unicode:characters_to_binary(Chars, Enc) of
        B when is_binary(B) -> B;
        _ -> <<>>
    end.

messages(Output) ->
    [message(L) || L <- binary:split(Output, <<"\n">>, [global, trim_all]),
                   string:trim(L) =/= <<>>].

message(Line) ->
    case re:run(Line, "^.*?\\.mib: ([0-9]+): (.*)$", [{capture, all_but_first, binary}, unicode]) of
        {match, [N, Msg]} -> #{line => binary_to_integer(N), message => string:trim(Msg)};
        nomatch ->
            case re:run(Line, "^.*?\\.mib: (.*)$", [{capture, all_but_first, binary}, unicode]) of
                {match, [Msg]} -> #{message => string:trim(Msg)};
                nomatch -> #{message => string:trim(Line)}
            end
    end.

remove_bin(Dir, Name) ->
    case file:delete(bin_path(Dir, Name)) of
        ok -> ok;
        {error, enoent} -> ok
    end.

remove_files(Dir, Name) ->
    _ = [file:delete(F) || F <- [bin_path(Dir, Name), meta_path(Dir, Name), src_path(Dir, Name)]],
    ok.

%% Files of modules that are no longer stored (deleted while not running).
cleanup(Dir, Stored) ->
    _ = [file:delete(F) || F <- filelib:wildcard(filename:join(Dir, "*.{mib,bin,meta}")),
                           not is_map_key(list_to_binary(filename:rootname(filename:basename(F))), Stored)],
    ok.

audit(Actor, Action, Name, Now) ->
    s2i_config_store:append_audit(#{at => Now, actor => Actor, action => Action, kind => mib, name => Name}).

transaction(Fun) ->
    case mnesia:transaction(fun() ->
                                    case Fun() of
                                        {error, _} = E -> mnesia:abort({return, E});
                                        Other -> Other
                                    end
                            end) of
        {atomic, Result} -> Result;
        {aborted, {return, E}} -> E;
        {aborted, Reason} -> error({mib_write_failed, Reason})
    end.
