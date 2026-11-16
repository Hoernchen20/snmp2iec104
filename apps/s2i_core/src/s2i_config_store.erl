-module(s2i_config_store).
-moduledoc """
Mnesia tables behind `s2i_config`. Single node, `disc_copies`.

| Table | Type | Content |
|---|---|---|
| `s2i_iec_server`, `s2i_profile`, `s2i_device` | set | staged entities: `{Tab, Name, SchemaVsn, Map}` |
| `s2i_config_version` | ordered_set | activated snapshots: `{Tab, Vsn, Meta, Config}` (immutable) |
| `s2i_audit` | ordered_set | `{Tab, Id, Entry}`, newest `?AUDIT_KEEP` entries |

The functions below the "inside a transaction" marker must be called within
`mnesia:transaction/1`.
""".

-export([start/0, tables/0]).
-export([read_staged/0, replace_staged/1, read_entity/2, write_entity/2, delete_entity/2,
         last_version/0, read_version/1, write_version/3, list_versions/0,
         append_audit/1, list_audit/1]).

-define(SCHEMA_VSN, 1).
-define(AUDIT_KEEP, 10000).

-define(ENTITY_TABLES, [{server, s2i_iec_server}, {profile, s2i_profile}, {device, s2i_device}]).

-spec tables() -> [atom()].
tables() ->
    [T || {_, T} <- ?ENTITY_TABLES] ++ [s2i_config_version, s2i_audit].

-doc """
Make sure Mnesia runs with a disc schema and all tables exist.

If Mnesia is not running yet, a disc schema is created in its `dir` (if
missing) and Mnesia is started. If it already runs with a RAM schema (started
as a plain application dependency without a schema on disc), the schema is
converted to `disc_copies`.
""".
-spec start() -> ok.
start() ->
    ok = ensure_disc_schema(),
    ok = lists:foreach(fun create_table/1, table_defs()),
    ok = mnesia:wait_for_tables(tables(), 30000).

table_defs() ->
    [{T, set, [name, schema_vsn, data]} || {_, T} <- ?ENTITY_TABLES] ++
    [{s2i_config_version, ordered_set, [vsn, meta, config]},
     {s2i_audit, ordered_set, [id, entry]}].

ensure_disc_schema() ->
    %% Mnesia creates its directory but not missing parents (e.g. "data/mnesia").
    ok = filelib:ensure_path(mnesia:system_info(directory)),
    case mnesia:system_info(is_running) of
        yes ->
            case mnesia:table_info(schema, storage_type) of
                disc_copies -> ok;
                ram_copies ->
                    {atomic, ok} = mnesia:change_table_copy_type(schema, node(), disc_copies),
                    ok
            end;
        no ->
            case mnesia:create_schema([node()]) of
                ok -> ok;
                {error, {_, {already_exists, _}}} -> ok
            end,
            ok = application:ensure_started(mnesia)
    end.

create_table({Tab, Type, Attrs}) ->
    case mnesia:create_table(Tab, [{type, Type}, {attributes, Attrs},
                                   {disc_copies, [node()]}]) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, Tab}} ->
            case mnesia:table_info(Tab, attributes) of
                Attrs -> ok;
                Other -> error({table_layout_mismatch, Tab, Other, Attrs})
            end
    end.

%%% ===========================================================================
%%% Inside a transaction
%%% ===========================================================================

-spec read_staged() -> s2i_validate:config().
read_staged() ->
    maps:from_list(
      [{Section, maps:from_list([{N, D} || {_, N, _, D} <- all(table(Kind))])}
       || {Section, Kind} <- s2i_validate:sections()]).

-spec replace_staged(s2i_validate:config()) -> ok.
replace_staged(Config) ->
    lists:foreach(
      fun({Section, Kind}) ->
              Tab = table(Kind),
              [mnesia:delete({Tab, K}) || K <- mnesia:all_keys(Tab)],
              [write_entity(Kind, E) || E <- maps:values(maps:get(Section, Config, #{}))]
      end, s2i_validate:sections()),
    ok.

-spec read_entity(s2i_schema:kind(), binary()) -> map() | undefined.
read_entity(Kind, Name) ->
    case mnesia:read(table(Kind), Name) of
        [{_, Name, _, Entity}] -> Entity;
        [] -> undefined
    end.

-spec write_entity(s2i_schema:kind(), map()) -> ok.
write_entity(Kind, #{name := Name} = Entity) ->
    mnesia:write({table(Kind), Name, ?SCHEMA_VSN, Entity}).

-spec delete_entity(s2i_schema:kind(), binary()) -> ok | {error, not_found}.
delete_entity(Kind, Name) ->
    Tab = table(Kind),
    case mnesia:read(Tab, Name) of
        [] -> {error, not_found};
        [_] -> mnesia:delete({Tab, Name})
    end.

-spec last_version() -> {ok, pos_integer(), s2i_validate:config()} | none.
last_version() ->
    case mnesia:last(s2i_config_version) of
        '$end_of_table' -> none;
        Vsn ->
            [{_, Vsn, _, Config}] = mnesia:read(s2i_config_version, Vsn),
            {ok, Vsn, Config}
    end.

-spec read_version(term()) -> {ok, s2i_validate:config()} | {error, not_found}.
read_version(Vsn) ->
    case mnesia:read(s2i_config_version, Vsn) of
        [{_, Vsn, _, Config}] -> {ok, Config};
        [] -> {error, not_found}
    end.

-spec write_version(pos_integer(), map(), s2i_validate:config()) -> ok.
write_version(Vsn, Meta, Config) ->
    mnesia:write({s2i_config_version, Vsn, Meta, Config}).

-doc "Version metadata, newest first.".
-spec list_versions() -> [map()].
list_versions() ->
    lists:reverse(lists:sort([Meta#{vsn => Vsn} || {_, Vsn, Meta, _} <- all(s2i_config_version)])).

-spec append_audit(map()) -> ok.
append_audit(Entry) ->
    Id = case mnesia:last(s2i_audit) of
             '$end_of_table' -> 1;
             Last -> Last + 1
         end,
    ok = mnesia:write({s2i_audit, Id, Entry#{id => Id}}),
    mnesia:delete({s2i_audit, Id - ?AUDIT_KEEP}).

-doc "Newest `Limit` audit entries, newest first.".
-spec list_audit(non_neg_integer()) -> [map()].
list_audit(Limit) ->
    list_audit(mnesia:last(s2i_audit), Limit).

list_audit('$end_of_table', _) -> [];
list_audit(_, 0) -> [];
list_audit(Id, Limit) ->
    [{_, Id, Entry}] = mnesia:read(s2i_audit, Id),
    [Entry | list_audit(mnesia:prev(s2i_audit, Id), Limit - 1)].

%%% ---------------------------------------------------------------------------

table(Kind) ->
    {Kind, Tab} = lists:keyfind(Kind, 1, ?ENTITY_TABLES),
    Tab.

all(Tab) ->
    mnesia:match_object(Tab, mnesia:table_info(Tab, wild_pattern), read).
