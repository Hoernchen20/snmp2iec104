-module(s2i_users).
-moduledoc """
Web users (docs/DESIGN.md §9.2), stored in the Mnesia table `s2i_user`
(`{s2i_user, Name, SchemaVsn, Map}`, created by `s2i_config_store`).

A user is `#{name, role => admin | viewer, password => s2i_password:hash(),
must_change_password, created_at, updated_at}`; the functions here return
it without the hash. Users are not part of the configuration versions (not
exported, not restored); changes are recorded in the same audit log.

- `put/3` creates a user (role and password required) or updates role and/or
  password. A password set by someone else must be changed by the user on
  the next login unless `must_change_password => false` is given.
- The last admin can neither be deleted nor demoted.
- `ensure_admin/2` creates the bootstrap admin (forced password change) when
  there are no users at all.
- `authenticate/2` spends the same time for unknown users and renews hashes
  with fewer than the configured iterations (`s2i_core`
  `password_iterations`, default 600 000).

Errors use the `s2i_schema` format `#{path, error}`.
""".

-export([list/0, get/1, put/3, delete/2, authenticate/2, change_password/3,
         ensure_admin/2, iterations/0]).
-export_type([user/0, role/0]).

-type role() :: admin | viewer.
-type user() :: #{name := binary(), role := role(), must_change_password := boolean(),
                  created_at := integer(), updated_at := integer()}.
-type errors() :: [s2i_schema:error()].

-define(TAB, s2i_user).
-define(SCHEMA_VSN, 1).
-define(DEFAULT_ITERATIONS, 600000).
-define(NAME_RE, "^[A-Za-z0-9][A-Za-z0-9_.@-]{0,63}$").

-spec iterations() -> pos_integer().
iterations() ->
    application:get_env(s2i_core, password_iterations, ?DEFAULT_ITERATIONS).

-doc "All users, sorted by name.".
-spec list() -> [user()].
list() ->
    [public(U) || {_, _, _, U} <- lists:keysort(2, mnesia:dirty_match_object({?TAB, '_', '_', '_'}))].

-spec get(binary()) -> {ok, user()} | {error, not_found}.
get(Name) when is_binary(Name) ->
    case mnesia:dirty_read(?TAB, Name) of
        [{_, Name, _, U}] -> {ok, public(U)};
        [] -> {error, not_found}
    end;
get(_) ->
    {error, not_found}.

-doc """
Create or update user `Name`. `Fields`: `role`, `password`,
`must_change_password` (binary or atom keys, as decoded JSON).
""".
-spec put(binary(), map(), s2i_config:actor()) -> {ok, user()} | {error, errors()}.
put(Name, Fields, Actor) when is_map(Fields) ->
    case parse(Name, Fields) of
        {ok, Parsed} ->
            %% hashing is slow: outside the transaction
            Hash = case Parsed of
                       #{password := P} -> s2i_password:hash(P, iterations());
                       _ -> undefined
                   end,
            transaction(fun() -> do_put(Name, Parsed, Hash, Actor) end);
        Error ->
            Error
    end;
put(_Name, _Fields, _Actor) ->
    {error, [#{path => [], error => invalid_type}]}.

-spec delete(binary(), s2i_config:actor()) -> ok | {error, not_found | last_admin}.
delete(Name, Actor) ->
    transaction(fun() ->
                        case mnesia:read(?TAB, Name, write) of
                            [] ->
                                {error, not_found};
                            [{_, _, _, #{role := Role}}] ->
                                case Role =:= admin andalso admins() =:= [Name] of
                                    true ->
                                        {error, last_admin};
                                    false ->
                                        ok = mnesia:delete({?TAB, Name}),
                                        audit(Actor, user_delete, Name)
                                end
                        end
                end).

-spec authenticate(term(), term()) -> {ok, user()} | {error, invalid_credentials}.
authenticate(Name, Password) when is_binary(Name), is_binary(Password) ->
    case mnesia:dirty_read(?TAB, Name) of
        [{_, Name, _, #{password := Hash} = U}] ->
            case s2i_password:verify(Password, Hash) of
                true ->
                    maybe_rehash(Name, Password, Hash),
                    {ok, public(U)};
                false ->
                    {error, invalid_credentials}
            end;
        [] ->
            s2i_password:dummy_verify(iterations()),
            {error, invalid_credentials}
    end;
authenticate(_Name, _Password) ->
    {error, invalid_credentials}.

-doc "The user changes their own password; clears `must_change_password`.".
-spec change_password(binary(), term(), term()) ->
          ok | {error, invalid_credentials | errors()}.
change_password(Name, Current, New) ->
    case authenticate(Name, Current) of
        {ok, _} ->
            case s2i_password:check_policy(New) of
                ok when New =:= Current ->
                    {error, [#{path => [new_password], error => unchanged}]};
                ok ->
                    Hash = s2i_password:hash(New, iterations()),
                    transaction(
                      fun() ->
                              case mnesia:read(?TAB, Name, write) of
                                  [{_, _, _, U}] ->
                                      write(U#{password := Hash, must_change_password := false,
                                               updated_at := now_ms()}),
                                      audit(Name, password_change, Name);
                                  [] ->
                                      {error, invalid_credentials}
                              end
                      end);
                {error, Code} ->
                    {error, [#{path => [new_password], error => Code}]}
            end;
        Error ->
            Error
    end.

-doc "Create the admin `Name` (forced password change) if there are no users.".
-spec ensure_admin(binary(), binary()) -> created | exists | {error, errors()}.
ensure_admin(Name, Password) ->
    case mnesia:table_info(?TAB, size) of
        0 ->
            case put(Name, #{role => admin, password => Password, must_change_password => true},
                     <<"system">>) of
                {ok, _} -> created;
                Error -> Error
            end;
        _ ->
            exists
    end.

%%% ===========================================================================
%%% Internals
%%% ===========================================================================

parse(Name, Fields) ->
    F = maps:fold(fun(K, V, Acc) when is_binary(K) ->
                          case [A || A <- [role, password, must_change_password],
                                     atom_to_binary(A) =:= K] of
                              [A] -> Acc#{A => V};
                              [] -> Acc#{K => V}
                          end;
                     (K, V, Acc) -> Acc#{K => V}
                  end, #{}, Fields),
    Errors = name_errors(Name)
        ++ [#{path => [K], error => unknown_field}
            || K <- maps:keys(F), not lists:member(K, [role, password, must_change_password, name])]
        ++ [#{path => [name], error => name_mismatch}
            || #{name := N} <- [F], N =/= Name]
        ++ field_errors(F),
    case Errors of
        [] -> {ok, maps:with([role, password, must_change_password],
                             maps:map(fun(role, R) -> role(R); (_, V) -> V end, F))};
        _ -> {error, Errors}
    end.

name_errors(Name) when is_binary(Name) ->
    case re:run(Name, ?NAME_RE, [unicode]) of
        {match, _} -> [];
        nomatch -> [#{path => [name], error => invalid_name}]
    end;
name_errors(_) ->
    [#{path => [name], error => invalid_name}].

field_errors(F) ->
    [#{path => [role], error => invalid_value}
     || #{role := R} <- [F], role(R) =:= undefined]
    ++ [#{path => [password], error => Code}
        || #{password := P} <- [F], {error, Code} <- [s2i_password:check_policy(P)]]
    ++ [#{path => [must_change_password], error => invalid_type}
        || #{must_change_password := M} <- [F], not is_boolean(M)].

role(R) when R =:= admin; R =:= <<"admin">> -> admin;
role(R) when R =:= viewer; R =:= <<"viewer">> -> viewer;
role(_) -> undefined.

do_put(Name, Parsed, Hash, Actor) ->
    Now = now_ms(),
    case mnesia:read(?TAB, Name, write) of
        [] ->
            Missing = [#{path => [K], error => required} || K <- [role, password],
                                                            not is_map_key(K, Parsed)],
            case Missing of
                [] ->
                    U = #{name => Name, role => maps:get(role, Parsed), password => Hash,
                          must_change_password => maps:get(must_change_password, Parsed, Actor =/= Name),
                          created_at => Now, updated_at => Now},
                    write(U),
                    ok = audit(Actor, user_put, Name),
                    {ok, public(U)};
                _ ->
                    {error, Missing}
            end;
        [{_, _, _, Old}] ->
            Role = maps:get(role, Parsed, maps:get(role, Old)),
            case maps:get(role, Old) =:= admin andalso Role =/= admin andalso admins() =:= [Name] of
                true ->
                    {error, [#{path => [role], error => last_admin}]};
                false ->
                    U0 = Old#{role := Role, updated_at := Now},
                    U1 = case Hash of
                             undefined -> U0;
                             _ -> U0#{password := Hash, must_change_password := Actor =/= Name}
                         end,
                    U = case Parsed of
                            #{must_change_password := M} -> U1#{must_change_password := M};
                            _ -> U1
                        end,
                    write(U),
                    ok = audit(Actor, user_put, Name),
                    {ok, public(U)}
            end
    end.

maybe_rehash(Name, Password, Hash) ->
    N = iterations(),
    case s2i_password:needs_rehash(Hash, N) of
        true ->
            New = s2i_password:hash(Password, N),
            _ = mnesia:transaction(fun() ->
                                           case mnesia:read(?TAB, Name, write) of
                                               [{_, _, _, #{password := Hash} = U}] ->
                                                   write(U#{password := New});
                                               _ ->
                                                   ok
                                           end
                                   end),
            ok;
        false ->
            ok
    end.

admins() ->
    [N || {_, N, _, #{role := admin}} <- mnesia:match_object(?TAB, {?TAB, '_', '_', '_'}, read)].

write(#{name := Name} = U) ->
    ok = mnesia:write({?TAB, Name, ?SCHEMA_VSN, U}).

audit(Actor, Action, Name) ->
    s2i_config_store:append_audit(#{at => now_ms(), actor => Actor, action => Action,
                                    kind => user, name => Name}).

public(U) ->
    maps:without([password], U).

transaction(Fun) ->
    case mnesia:transaction(fun() ->
                                    case Fun() of
                                        {error, _} = E -> mnesia:abort({return, E});
                                        Other -> Other
                                    end
                            end) of
        {atomic, Result} -> Result;
        {aborted, {return, E}} -> E;
        {aborted, Reason} -> error({user_write_failed, Reason})
    end.

now_ms() ->
    erlang:system_time(millisecond).
