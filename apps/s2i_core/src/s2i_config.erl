-module(s2i_config).
-moduledoc """
Configuration service: staged edits, validated activation, versions, audit.

- **Staged** configuration is edited entity by entity (`put/3`, `delete/3`) or
  replaced as a whole (`import/2`, `revert/1`, `restore/2`). Each entity is
  schema-checked on write; references between entities are not, so the
  staged configuration may be temporarily inconsistent.
- `activate/2` validates the complete staged configuration (`s2i_validate`)
  and stores it as a new **immutable version**. The newest version is the
  **active** configuration. Subscribers receive
  `{s2i_config, {activated, Vsn}}`.
- Every change is recorded in the audit log together with its actor.

Writes are serialised through this process; reads go to Mnesia directly from
the caller.
""".
-behaviour(gen_server).

-export([start_link/0, child_spec/0]).
-export([put/3, delete/3, get/2, list/1, staged/0,
         validate/0, activate/2, active/0, has_changes/0,
         versions/0, version/1, revert/1, restore/2,
         export/1, import/2,
         audit/1, subscribe/0, unsubscribe/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-type actor() :: binary().
-type errors() :: [s2i_schema:error()].
-export_type([actor/0]).

%%% ===========================================================================
%%% API
%%% ===========================================================================

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec child_spec() -> supervisor:child_spec().
child_spec() ->
    #{id => ?MODULE, start => {?MODULE, start_link, []}, type => worker}.

-doc "Create or replace a staged entity. Returns its canonical form.".
-spec put(s2i_schema:kind(), map(), actor()) -> {ok, map()} | {error, errors()}.
put(Kind, Entity, Actor) ->
    gen_server:call(?MODULE, {put, Kind, Entity, Actor}).

-spec delete(s2i_schema:kind(), binary(), actor()) -> ok | {error, not_found}.
delete(Kind, Name, Actor) ->
    gen_server:call(?MODULE, {delete, Kind, Name, Actor}).

-spec get(s2i_schema:kind(), binary()) -> {ok, map()} | {error, not_found}.
get(Kind, Name) ->
    Section = section(Kind),
    case maps:find(Name, maps:get(Section, staged())) of
        {ok, E} -> {ok, E};
        error -> {error, not_found}
    end.

-doc "Staged entities of one kind, sorted by name.".
-spec list(s2i_schema:kind()) -> [map()].
list(Kind) ->
    [E || _ := E <- maps:iterator(maps:get(section(Kind), staged()), ordered)].

-spec staged() -> s2i_validate:config().
staged() ->
    read(fun s2i_config_store:read_staged/0).

-doc "Validate the staged configuration without activating it.".
-spec validate() -> ok | {error, errors()}.
validate() ->
    case validate_for_activation(staged()) of
        {ok, _} -> ok;
        Error -> Error
    end.

-spec activate(actor(), binary()) ->
          {ok, pos_integer()} | {error, no_changes | errors()}.
activate(Actor, Comment) ->
    gen_server:call(?MODULE, {activate, Actor, Comment}).

-spec active() -> {ok, pos_integer(), s2i_validate:config()} | {error, none}.
active() ->
    case read(fun s2i_config_store:last_version/0) of
        {ok, Vsn, Config} -> {ok, Vsn, Config};
        none -> {error, none}
    end.

-doc "Whether the staged configuration differs from the active one.".
-spec has_changes() -> boolean().
has_changes() ->
    read(fun() -> s2i_config_store:read_staged() =/= active_or_empty() end).

-doc "Metadata of all versions, newest first.".
-spec versions() -> [#{vsn := pos_integer(), at := integer(), author := actor(),
                       comment := binary()}].
versions() ->
    read(fun s2i_config_store:list_versions/0).

-spec version(pos_integer()) -> {ok, s2i_validate:config()} | {error, not_found}.
version(Vsn) ->
    read(fun() -> s2i_config_store:read_version(Vsn) end).

-doc "Discard staged changes: staged becomes the active configuration (or empty).".
-spec revert(actor()) -> ok.
revert(Actor) ->
    gen_server:call(?MODULE, {revert, Actor}).

-doc "Load an older version into the staged configuration (activate to roll back).".
-spec restore(pos_integer(), actor()) -> ok | {error, not_found}.
restore(Vsn, Actor) ->
    gen_server:call(?MODULE, {restore, Vsn, Actor}).

-doc "The staged or active configuration in its JSON-safe canonical form.".
-spec export(staged | active) -> {ok, s2i_validate:config()} | {error, none}.
export(staged) ->
    {ok, staged()};
export(active) ->
    case active() of
        {ok, _, Config} -> {ok, Config};
        Error -> Error
    end.

-doc "Replace the whole staged configuration, e.g. with decoded JSON.".
-spec import(term(), actor()) -> ok | {error, errors()}.
import(Config, Actor) ->
    gen_server:call(?MODULE, {import, Config, Actor}).

-doc "Newest `Limit` audit entries, newest first.".
-spec audit(non_neg_integer()) -> [map()].
audit(Limit) ->
    read(fun() -> s2i_config_store:list_audit(Limit) end).

-doc "Receive `{s2i_config, {activated, Vsn}}` after every activation.".
-spec subscribe() -> ok.
subscribe() ->
    gen_server:call(?MODULE, {subscribe, self()}).

-spec unsubscribe() -> ok.
unsubscribe() ->
    gen_server:call(?MODULE, {unsubscribe, self()}).

%%% ===========================================================================
%%% gen_server
%%% ===========================================================================

-spec init([]) -> {ok, #{subscribers := #{pid() => reference()}}} | {stop, term()}.
init([]) ->
    {ok, KeyFile} = application:get_env(s2i_core, secret_key_file),
    case s2i_secret:load(KeyFile) of
        ok ->
            ok = s2i_config_store:start(),
            {ok, #{subscribers => #{}}};
        {error, Reason} ->
            logger:error("Cannot load secret key ~ts: ~p", [KeyFile, Reason]),
            {stop, Reason}
    end.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call({put, Kind, Entity, Actor}, _From, State) ->
    Reply = case s2i_schema:normalize(Kind, Entity) of
                {ok, #{name := Name} = N} ->
                    write(fun() ->
                                  Old = s2i_config_store:read_entity(Kind, Name),
                                  case s2i_secret:seal_entity(Kind, N, Old) of
                                      {ok, Sealed} ->
                                          ok = s2i_config_store:write_entity(Kind, Sealed),
                                          audit(Actor, put, #{kind => Kind, name => Name}),
                                          {ok, Sealed};
                                      Error ->
                                          Error
                                  end
                          end);
                Error ->
                    Error
            end,
    {reply, Reply, State};
handle_call({delete, Kind, Name, Actor}, _From, State) ->
    Reply = write(fun() ->
                          case s2i_config_store:delete_entity(Kind, Name) of
                              ok -> audit(Actor, delete, #{kind => Kind, name => Name});
                              Error -> Error
                          end
                  end),
    {reply, Reply, State};
handle_call({activate, Actor, Comment}, _From, State) ->
    Reply = write(fun() -> do_activate(Actor, Comment) end),
    case Reply of
        {ok, Vsn} -> notify(State, {activated, Vsn});
        _ -> ok
    end,
    {reply, Reply, State};
handle_call({revert, Actor}, _From, State) ->
    Reply = write(fun() ->
                          ok = s2i_config_store:replace_staged(active_or_empty()),
                          audit(Actor, revert, #{})
                  end),
    {reply, Reply, State};
handle_call({restore, Vsn, Actor}, _From, State) ->
    Reply = write(fun() ->
                          case s2i_config_store:read_version(Vsn) of
                              {ok, Config} ->
                                  ok = s2i_config_store:replace_staged(Config),
                                  audit(Actor, restore, #{vsn => Vsn});
                              Error ->
                                  Error
                          end
                  end),
    {reply, Reply, State};
handle_call({import, Config, Actor}, _From, State) ->
    Reply = case s2i_validate:entities(Config) of
                {ok, Norm} ->
                    write(fun() ->
                                  case seal_config(Norm, s2i_config_store:read_staged()) of
                                      {ok, Sealed} ->
                                          ok = s2i_config_store:replace_staged(Sealed),
                                          audit(Actor, import, #{});
                                      Error ->
                                          Error
                                  end
                          end);
                Error ->
                    Error
            end,
    {reply, Reply, State};
handle_call({subscribe, Pid}, _From, State = #{subscribers := Subs}) ->
    Subs1 = case is_map_key(Pid, Subs) of
                true -> Subs;
                false -> Subs#{Pid => monitor(process, Pid)}
            end,
    {reply, ok, State#{subscribers := Subs1}};
handle_call({unsubscribe, Pid}, _From, State = #{subscribers := Subs}) ->
    case maps:take(Pid, Subs) of
        {Ref, Subs1} ->
            demonitor(Ref, [flush]),
            {reply, ok, State#{subscribers := Subs1}};
        error ->
            {reply, ok, State}
    end.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info({'DOWN', _Ref, process, Pid, _}, State = #{subscribers := Subs}) ->
    {noreply, State#{subscribers := maps:remove(Pid, Subs)}};
handle_info(_Msg, State) ->
    {noreply, State}.

%%% ===========================================================================
%%% Internals
%%% ===========================================================================

do_activate(Actor, Comment) ->
    Staged = s2i_config_store:read_staged(),
    {LastVsn, Active} = case s2i_config_store:last_version() of
                            {ok, V, C} -> {V, C};
                            none -> {0, s2i_validate:empty()}
                        end,
    case Staged =:= Active of
        true ->
            {error, no_changes};
        false ->
            case validate_for_activation(Staged) of
                {ok, Config} ->
                    Vsn = LastVsn + 1,
                    Meta = #{at => now_ms(), author => Actor, comment => Comment},
                    ok = s2i_config_store:write_version(Vsn, Meta, Config),
                    ok = audit(Actor, activate, #{vsn => Vsn}),
                    {ok, Vsn};
                Error ->
                    Error
            end
    end.

%% Secrets that no longer decrypt (key file replaced) block activation.
validate_for_activation(Staged) ->
    case s2i_validate:config(Staged) of
        {ok, Config} ->
            case s2i_secret:check_config(Config) of
                [] -> {ok, Config};
                Errors -> {error, Errors}
            end;
        Error ->
            Error
    end.

%% Seal all secrets of an imported config; unchanged plaintext keeps the
%% ciphertext of the currently staged entity of the same name.
seal_config(Config, Current) ->
    {Sealed, Errors} =
        lists:foldl(
          fun({Section, Kind}, {Acc, Errs}) ->
                  Cur = maps:get(Section, Current),
                  {S, E} = maps:fold(
                             fun(Name, Entity, {SAcc, EAcc}) ->
                                     case s2i_secret:seal_entity(Kind, Entity, maps:get(Name, Cur, undefined)) of
                                         {ok, X} -> {SAcc#{Name => X}, EAcc};
                                         {error, Es} -> {SAcc, EAcc ++ [E#{path := [Section, Name | P]}
                                                                        || #{path := P} = E <- Es]}
                                     end
                             end, {#{}, []}, maps:get(Section, Config)),
                  {Acc#{Section => S}, Errs ++ E}
          end, {#{}, []}, s2i_validate:sections()),
    case Errors of
        [] -> {ok, Sealed};
        _ -> {error, Errors}
    end.

active_or_empty() ->
    case s2i_config_store:last_version() of
        {ok, _, Config} -> Config;
        none -> s2i_validate:empty()
    end.

audit(Actor, Action, Extra) ->
    s2i_config_store:append_audit(Extra#{at => now_ms(), actor => Actor, action => Action}).

notify(#{subscribers := Subs}, Event) ->
    _ = [Pid ! {?MODULE, Event} || Pid <- maps:keys(Subs)],
    ok.

section(Kind) ->
    {Section, Kind} = lists:keyfind(Kind, 2, s2i_validate:sections()),
    Section.

%% Writes abort on {error, _} so no partial change (e.g. audit without data)
%% is ever committed.
write(Fun) ->
    case mnesia:transaction(fun() ->
                                    case Fun() of
                                        {error, _} = E -> mnesia:abort({return, E});
                                        Other -> Other
                                    end
                            end) of
        {atomic, Result} -> Result;
        {aborted, {return, E}} -> E;
        {aborted, Reason} -> error({config_write_failed, Reason})
    end.

read(Fun) ->
    {atomic, Result} = mnesia:transaction(Fun),
    Result.

now_ms() ->
    erlang:system_time(millisecond).
