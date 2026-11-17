-module(s2i_mib_index).
-moduledoc """
Name index of the loaded MIBs (docs/DESIGN.md §13): OID ↔ name, syntax,
enum labels, notifications. UI assist only; the runtime never looks here.

`defs/2` turns a compiled MIB (`snmp_misc:read_mib/1`) into definitions;
`build/1` puts the definitions of all modules into two ETS tables:

- OIDs (`ordered_set`, so the OID tree is a key range): `{Oid, [Def]}`, more
  than one definition when modules overlap (RFC1213-MIB and IF-MIB), the
  first in load order wins for display;
- names (`set`): `{Name, [{Module, Oid}]}`.

The query functions take the `{OidTab, NameTab}` pair.
""".

%% OTP's snmp records have untyped fields
-compile(nowarn_untyped_record).
-include_lib("snmp/include/snmp_types.hrl").

-export([defs/2, smi_defs/0, build/1, delete/1]).
-export([lookup/2, translate/2, resolve/2, children/2, search/3]).
-export_type([def/0, tables/0]).

-type oid() :: [non_neg_integer()].
-type def() :: #{oid := oid(), name := binary(), module := binary(),
                 kind := node | scalar | table | row | column | notification,
                 syntax => binary(), base_type => binary(), range => [integer()],
                 enums => [#{value := integer(), name := binary()}],
                 bits => [#{bit := non_neg_integer(), name := binary()}],
                 access => binary(), units => binary(), description => binary(),
                 objects => [oid()]}.
-type tables() :: {ets:tid(), ets:tid()}.

%%% ===========================================================================
%%% Definitions
%%% ===========================================================================

-doc "The definitions a compiled MIB adds (imported nodes are left out).".
-spec defs(binary(), #mib{}) -> [def()].
defs(Module, #mib{mes = Mes, traps = Traps}) ->
    [me_def(Module, Me) || #me{imported = false} = Me <- Mes]
    ++ [trap_def(Module, T) || T <- Traps].

me_def(Module, #me{oid = Oid, entrytype = Type, aliasname = Name, asn1_type = Asn1,
                   access = Access, description = Descr, units = Units}) ->
    Base = #{oid => Oid, name => atom_to_binary(Name), module => Module, kind => kind(Type)},
    lists:foldl(fun maps:merge/2, Base,
                [syntax(Asn1),
                 opt(access, Access, fun atom_to_binary/1),
                 opt(units, Units, fun text/1),
                 opt(description, Descr, fun description/1)]).

kind(internal) -> node;
kind(variable) -> scalar;
kind(table) -> table;
kind(table_entry) -> row;
kind(table_column) -> column;
kind(_) -> node.

syntax(#asn1_type{bertype = Ber, lo = Lo, hi = Hi, assocList = Assoc, aliasname = Alias}) ->
    Range = case is_integer(Lo) andalso is_integer(Hi) of
                true -> #{range => [Lo, Hi]};
                false -> #{}
            end,
    Enums = case proplists:get_value(enums, Assoc) of
                Es when is_list(Es), Es =/= [] ->
                    #{enums => [#{value => V, name => atom_to_binary(N)} || {N, V} <- lists:keysort(2, Es)]};
                _ ->
                    #{}
            end,
    Bits = case proplists:get_value(kibbles, Assoc) of
               Ks when is_list(Ks), Ks =/= [] ->
                   #{bits => [#{bit => B, name => atom_to_binary(N)} || {N, B} <- lists:keysort(2, Ks)]};
               _ ->
                   #{}
           end,
    maps:merge(#{syntax => name(Alias, Ber), base_type => name(Ber, Ber)},
               maps:merge(Range, maps:merge(Enums, Bits)));
syntax(_) ->
    #{}.

name(A, _) when is_atom(A), A =/= undefined -> atom_to_binary(A);
name(_, B) -> atom_to_binary(B).

trap_def(Module, #notification{trapname = Name, oid = Oid, oidobjects = Objs, description = D}) ->
    maps:merge(#{oid => Oid, name => atom_to_binary(Name), module => Module, kind => notification,
                 objects => objects(Objs)},
               opt(description, D, fun text/1));
trap_def(Module, #trap{trapname = Name, enterpriseoid = E, specificcode = S, oidobjects = Objs, description = D}) ->
    %% SNMPv1 TRAP-TYPE as its SNMPv2 trap OID (RFC 3584 §3.1)
    maps:merge(#{oid => E ++ [0, S], name => atom_to_binary(Name), module => Module, kind => notification,
                 objects => objects(Objs)},
               opt(description, D, fun description/1)).

objects(Objs) when is_list(Objs) -> [Oid || {Oid, _Type} <- Objs];
objects(_) -> [].

opt(_Key, undefined, _F) -> #{};
opt(_Key, [], _F) -> #{};
opt(Key, V, F) -> #{Key => F(V)}.

%% A DESCRIPTION without the indentation its continuation lines have in the source.
description(L) ->
    [First | Rest] = binary:split(text(L), <<"\n">>, [global]),
    Indents = [indent(Line, 0) || Line <- Rest, string:trim(Line) =/= <<>>],
    Cut = case Indents of
              [] -> 0;
              _ -> lists:min(Indents)
          end,
    iolist_to_binary(lists:join(<<"\n">>, [string:trim(First, leading)
                                          | [dedent(Line, Cut) || Line <- Rest]])).

indent(<<C, Rest/binary>>, N) when C =:= $\s; C =:= $\t -> indent(Rest, N + 1);
indent(_, N) -> N.

dedent(Line, Cut) when byte_size(Line) >= Cut -> string:trim(binary:part(Line, Cut, byte_size(Line) - Cut), trailing);
dedent(_Line, _Cut) -> <<>>.

%% Compiled descriptions are the bytes of the source: UTF-8 if valid, else Latin-1.
text(L) when is_list(L) ->
    B = list_to_binary(L),
    case unicode:characters_to_binary(B) of
        B -> B;
        _ -> unicode:characters_to_binary(B, latin1)
    end.

-doc "The nodes snmpc builds in (SNMPv2-SMI / RFC1155-SMI), the roots of every tree.".
-spec smi_defs() -> [def()].
smi_defs() ->
    [#{oid => Oid, name => Name, module => <<"SNMPv2-SMI">>, kind => node}
     || {Name, Oid} <- [{<<"ccitt">>, [0]}, {<<"zeroDotZero">>, [0, 0]},
                        {<<"iso">>, [1]}, {<<"org">>, [1, 3]}, {<<"dod">>, [1, 3, 6]},
                        {<<"internet">>, [1, 3, 6, 1]}, {<<"directory">>, [1, 3, 6, 1, 1]},
                        {<<"mgmt">>, [1, 3, 6, 1, 2]}, {<<"mib-2">>, [1, 3, 6, 1, 2, 1]},
                        {<<"transmission">>, [1, 3, 6, 1, 2, 1, 10]},
                        {<<"experimental">>, [1, 3, 6, 1, 3]}, {<<"private">>, [1, 3, 6, 1, 4]},
                        {<<"enterprises">>, [1, 3, 6, 1, 4, 1]}, {<<"security">>, [1, 3, 6, 1, 5]},
                        {<<"snmpV2">>, [1, 3, 6, 1, 6]}, {<<"snmpDomains">>, [1, 3, 6, 1, 6, 1]},
                        {<<"snmpProxys">>, [1, 3, 6, 1, 6, 2]}, {<<"snmpModules">>, [1, 3, 6, 1, 6, 3]},
                        {<<"joint-iso-ccitt">>, [2]}]].

%%% ===========================================================================
%%% Tables
%%% ===========================================================================

-doc "New tables with `Defs`; earlier definitions of an OID come first.".
-spec build([def()]) -> tables().
build(Defs) ->
    Oids = ets:new(s2i_mib_oids, [ordered_set, protected, {read_concurrency, true}]),
    Names = ets:new(s2i_mib_names, [set, protected, {read_concurrency, true}]),
    ByOid = lists:foldl(fun(#{oid := O} = D, Acc) -> maps:update_with(O, fun(L) -> [D | L] end, [D], Acc) end,
                        #{}, Defs),
    true = ets:insert(Oids, [{O, lists:reverse(Ds)} || O := Ds <- ByOid]),
    ByName = lists:foldl(fun(#{name := N, module := M, oid := O}, Acc) ->
                                 maps:update_with(N, fun(L) -> [{M, O} | L] end, [{M, O}], Acc)
                         end, #{}, Defs),
    true = ets:insert(Names, [{N, lists:usort(L)} || N := L <- ByName]),
    {Oids, Names}.

-spec delete(tables()) -> ok.
delete({Oids, Names}) ->
    true = ets:delete(Oids),
    true = ets:delete(Names),
    ok.

-doc "The definition of exactly this OID.".
-spec lookup(tables(), oid()) -> {ok, def()} | error.
lookup({Oids, _}, Oid) ->
    case ets:lookup(Oids, Oid) of
        [{_, [D | _]}] -> {ok, D};
        [] -> error
    end.

-doc """
The definition of the longest known prefix of `Oid` and the rest as the
index (`ifOperStatus` + `[3]`).
""".
-spec translate(tables(), oid()) -> {ok, def(), oid()} | error.
translate(Tabs, Oid) ->
    translate(Tabs, lists:reverse(Oid), []).

translate(_Tabs, [], _Suffix) ->
    error;
translate(Tabs, [Last | RevPrefix] = Rev, Suffix) ->
    case lookup(Tabs, lists:reverse(Rev)) of
        {ok, D} -> {ok, D, Suffix};
        error -> translate(Tabs, RevPrefix, [Last | Suffix])
    end.

-doc """
A name to its OID: `ifInOctets`, `IF-MIB::ifInOctets` or either with an
index (`ifInOctets.3`); a numeric OID is returned as it is. A name defined
with different OIDs in several modules needs the module.
""".
-spec resolve(tables(), binary()) ->
          {ok, oid()} | {error, invalid | not_found | {ambiguous, [binary()]}}.
resolve({_, Names}, Text) ->
    Re = "^\\s*(?:([A-Za-z][A-Za-z0-9-]*)::)?([A-Za-z][A-Za-z0-9-]*)((?:\\.[0-9]+)*)\\s*$",
    case re:run(Text, Re, [{capture, all_but_first, binary}]) of
        {match, [Module, Name, Index]} ->
            Suffix = [binary_to_integer(I) || I <- binary:split(Index, <<".">>, [global, trim_all])],
            Candidates = case ets:lookup(Names, Name) of
                             [{_, L}] -> [{M, O} || {M, O} <- L, Module =:= <<>> orelse M =:= Module];
                             [] -> []
                         end,
            case lists:usort([O || {_, O} <- Candidates]) of
                [] -> {error, not_found};
                [Oid] -> {ok, Oid ++ Suffix};
                _ -> {error, {ambiguous, lists:usort([M || {M, _} <- Candidates])}}
            end;
        nomatch ->
            case numeric(Text) of
                {ok, Oid} -> {ok, Oid};
                error -> {error, invalid}
            end
    end.

numeric(Text) ->
    case re:run(Text, "^\\s*\\.?([0-9]+(?:\\.[0-9]+)*)\\s*$", [{capture, all_but_first, binary}]) of
        {match, [Dotted]} -> {ok, [binary_to_integer(I) || I <- binary:split(Dotted, <<".">>, [global])]};
        nomatch -> error
    end.

-doc """
The direct children of `Oid` that have definitions below them: the child
arc, its definition (`undefined` for an unnamed intermediate arc) and
whether it has children itself.
""".
-spec children(tables(), oid()) -> [{oid(), def() | undefined, boolean()}].
children({Oids, _} = Tabs, Prefix) ->
    children(Tabs, Prefix, ets:next(Oids, Prefix), []).

children({Oids, _} = Tabs, Prefix, Key, Acc) ->
    case below(Prefix, Key) of
        {true, Arc} ->
            Child = Prefix ++ [Arc],
            Def = case lookup(Tabs, Child) of
                      {ok, D} -> D;
                      error -> undefined
                  end,
            HasChildren = Key =/= Child orelse below(Child, ets:next(Oids, Child)) =/= false,
            %% every key below Child sorts before Child ++ [Arc'] for any atom Arc'
            children(Tabs, Prefix, ets:next(Oids, Child ++ ['$end']), [{Child, Def, HasChildren} | Acc]);
        false ->
            lists:reverse(Acc)
    end.

below(Prefix, Key) when is_list(Key) ->
    case lists:prefix(Prefix, Key) andalso length(Key) > length(Prefix) of
        true -> {true, lists:nth(length(Prefix) + 1, Key)};
        false -> false
    end;
below(_Prefix, _EndOfTable) ->
    false.

-doc """
Definitions whose name contains `Query` (case-insensitive): exact matches
first, then prefix matches, then the rest; shorter names first.
""".
-spec search(tables(), binary(), pos_integer()) -> [def()].
search({_, Names} = Tabs, Query, Limit) ->
    Q = string:lowercase(Query),
    Hits = ets:foldl(fun({Name, Refs}, Acc) ->
                             L = string:lowercase(Name),
                             case binary:match(L, Q) of
                                 nomatch -> Acc;
                                 {Pos, _} ->
                                     Rank = if L =:= Q -> 0; Pos =:= 0 -> 1; true -> 2 end,
                                     [{{Rank, byte_size(Name), Name, M}, O} || {M, O} <- Refs] ++ Acc
                             end
                     end, [], Names),
    Unique = dedup_oids(lists:sort(Hits), #{}),
    [def_of(Tabs, O, Name) || {{_, _, Name, _}, O} <- lists:sublist(Unique, Limit)].

dedup_oids([], _Seen) -> [];
dedup_oids([{_, O} | T], Seen) when is_map_key(O, Seen) -> dedup_oids(T, Seen);
dedup_oids([{_, O} = H | T], Seen) -> [H | dedup_oids(T, Seen#{O => true})].

%% the first definition (in load order) of the OID with the name that matched
def_of({Oids, _}, Oid, Name) ->
    [{_, Ds}] = ets:lookup(Oids, Oid),
    case [D || #{name := N} = D <- Ds, N =:= Name] of
        [D | _] -> D;
        [] -> hd(Ds)
    end.
