-module(s2i_web_mib).
-moduledoc """
JSON shapes of the MIB library for the REST API (pure, docs/DESIGN.md §13).
The index lookups are passed in as functions (`s2i_mibs:translate/1`,
`s2i_mibs:lookup/1`), so this module does not depend on a running index.

- `info/2`: what a numeric OID is (`ifOperStatus` + index `3`): name,
  module, kind, syntax and enum labels, without the description; for lists
  of values (translate, search).
- `detail/2`: a definition with description, access, range and the objects
  of a notification (each translated).
- `node/4`: one node of the OID tree, its ancestors (breadcrumb) and children.
""".

-export([info/2, detail/2, node/4, parse_oid/1]).

-type oid() :: [non_neg_integer()].
-type translate() :: fun((oid()) -> {ok, s2i_mib_index:def(), oid()} | error).
-type lookup() :: fun((oid()) -> {ok, s2i_mib_index:def()} | error).

-define(INFO_KEYS, [name, module, kind, syntax, base_type, enums, bits, units]).

-doc "Compact description of a definition matched with an index suffix.".
-spec info(s2i_mib_index:def(), oid()) -> map().
info(#{oid := Base} = Def, Suffix) ->
    (maps:with(?INFO_KEYS, Def))#{oid => s2i_web_json:oid(Base ++ Suffix),
                                  base_oid => s2i_web_json:oid(Base),
                                  index => s2i_web_json:oid(Suffix)}.

-doc "Full description of a definition.".
-spec detail(s2i_mib_index:def(), translate()) -> map().
detail(Def, Translate) ->
    D = maps:merge(info(Def, []), maps:with([access, units, description, range], Def)),
    case Def of
        #{objects := Objs} -> D#{objects => [object(O, Translate) || O <- Objs]};
        _ -> D
    end.

object(Oid, Translate) ->
    case Translate(Oid) of
        {ok, Def, Suffix} -> info(Def, Suffix);
        error -> #{oid => s2i_web_json:oid(Oid)}
    end.

-doc """
A node of the OID tree: its own definition (`null` for an unnamed arc), the
ancestors from the root and the children with definitions below them.
""".
-spec node(oid(), [{oid(), s2i_mib_index:def() | undefined, boolean()}], lookup(), translate()) -> map().
node(Oid, Children, Lookup, Translate) ->
    Def = case Lookup(Oid) of
              {ok, D} -> detail(D, Translate);
              error -> null
          end,
    Path = [#{oid => s2i_web_json:oid(P), name => name(Lookup(P))}
            || N <- lists:seq(1, length(Oid) - 1), P <- [lists:sublist(Oid, N)]],
    #{oid => s2i_web_json:oid(Oid),
      def => Def,
      path => Path,
      children => [child(C, D, Has) || {C, D, Has} <- Children]}.

child(Oid, Def, HasChildren) ->
    Base = #{oid => s2i_web_json:oid(Oid), arc => lists:last(Oid), has_children => HasChildren},
    case Def of
        undefined -> Base#{name => null};
        _ -> maps:merge(Base, maps:with([name, module, kind, syntax], Def))
    end.

name({ok, #{name := N}}) -> N;
name(error) -> null.

-doc "A dotted numeric OID with at least one arc (the tree starts at `1`).".
-spec parse_oid(binary()) -> {ok, oid()} | error.
parse_oid(<<".", B/binary>>) ->
    parse_oid(B);
parse_oid(B) when is_binary(B), B =/= <<>>, byte_size(B) =< 1024 ->
    try [binary_to_integer(P) || P <- binary:split(B, <<".">>, [global])] of
        Oid ->
            case lists:all(fun(I) -> I >= 0 andalso I =< 4294967295 end, Oid) of
                true -> {ok, Oid};
                false -> error
            end
    catch
        error:badarg -> error
    end;
parse_oid(_) ->
    error.
