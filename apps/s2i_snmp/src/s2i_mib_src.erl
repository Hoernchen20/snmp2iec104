-module(s2i_mib_src).
-moduledoc """
MIB sources before compilation (pure, docs/DESIGN.md §13).

- `split/1`: a file into its ASN.1 modules (vendor files often bundle
  several), each with its name and the modules it imports. Comments and
  string literals are masked first, so `-- FROM X` or `"... END ..."` in a
  DESCRIPTION do not count.
- `order/2`: compile order of the uploaded modules (imports first), and why
  the others cannot be compiled (missing imports, or a dependency that is
  itself blocked, including import cycles).
- `cache_key/3`: identity of a compiled module: its source, the keys of the
  uploaded modules it imports and the compiler version. An unchanged key
  means the cached `.bin` is still valid.
""".

-export([split/1, order/2, cache_key/3, valid_name/1]).
-export_type([module_src/0, blocked/0]).

-type name() :: binary().
-type module_src() :: #{name := name(), imports := [name()], source := binary()}.
-type blocked() :: {missing, [name()]} | {dependency, [name()]}.

-define(ID, "[A-Za-z][A-Za-z0-9-]*").
-define(NOT_ID, "(?<![A-Za-z0-9-])").
-define(NOT_ID_AFTER, "(?![A-Za-z0-9-])").

-doc """
The modules in a MIB file. Text before the first module (comments) belongs to
it; each module runs up to the start of the next one.
""".
-spec split(binary()) ->
          {ok, [module_src()]} | {error, no_module | {no_end, name()} | {invalid_name, name()}}.
split(Source) when is_binary(Source) ->
    Masked = mask(Source),
    Re = ?NOT_ID "(" ?ID ")\\s+(?:\\{[^}]*\\}\\s*)?DEFINITIONS" ?NOT_ID_AFTER "[^:]*::=\\s*BEGIN" ?NOT_ID_AFTER,
    case re:run(Masked, Re, [global, {capture, [0, 1], index}]) of
        nomatch ->
            {error, no_module};
        {match, Matches} ->
            Starts = [S || [{S, _}, _] <- Matches],
            Names = [binary:part(Masked, N) || [_, N] <- Matches],
            Bounds = lists:zip([0 | tl(Starts)], tl(Starts) ++ [byte_size(Source)]),
            modules(lists:zip(Names, Bounds), Source, Masked, [])
    end.

modules([], _Source, _Masked, Acc) ->
    {ok, lists:reverse(Acc)};
modules([{Name, {From, To}} | Rest], Source, Masked, Acc) ->
    Text = binary:part(Masked, From, To - From),
    case {valid_name(Name), re:run(Text, ?NOT_ID "END" ?NOT_ID_AFTER, [{capture, none}])} of
        {false, _} ->
            {error, {invalid_name, Name}};
        {true, nomatch} ->
            {error, {no_end, Name}};
        {true, match} ->
            M = #{name => Name, imports => imports(Text), source => binary:part(Source, From, To - From)},
            modules(Rest, Source, Masked, [M | Acc])
    end.

-doc "A module name that is safe as a file name: an ASN.1 identifier.".
-spec valid_name(term()) -> boolean().
valid_name(Name) when is_binary(Name), byte_size(Name) =< 128 ->
    re:run(Name, "^" ?ID "$", [{capture, none}]) =:= match;
valid_name(_) ->
    false.

imports(Masked) ->
    case re:run(Masked, ?NOT_ID "IMPORTS" ?NOT_ID_AFTER "(.*?);", [dotall, {capture, all_but_first, binary}]) of
        {match, [Section]} ->
            case re:run(Section, ?NOT_ID "FROM\\s+(" ?ID ")", [global, {capture, all_but_first, binary}]) of
                {match, Ms} -> lists:usort([M || [M] <- Ms]);
                nomatch -> []
            end;
        nomatch ->
            []
    end.

%% Comments (`--` to the end of the line or the next `--`) and the contents of
%% string literals become spaces; newlines stay, so offsets and line numbers
%% are those of the source.
mask(Source) ->
    mask(Source, code, <<>>).

mask(<<>>, _State, Acc) ->
    Acc;
mask(<<"\n", Rest/binary>>, comment, Acc) ->
    mask(Rest, code, <<Acc/binary, "\n">>);
mask(<<"--", Rest/binary>>, comment, Acc) ->
    mask(Rest, code, <<Acc/binary, "  ">>);
mask(<<"--", Rest/binary>>, code, Acc) ->
    mask(Rest, comment, <<Acc/binary, "  ">>);
mask(<<"\"", Rest/binary>>, code, Acc) ->
    mask(Rest, string, <<Acc/binary, "\"">>);
mask(<<"\"", Rest/binary>>, string, Acc) ->
    mask(Rest, code, <<Acc/binary, "\"">>);
mask(<<"\n", Rest/binary>>, string, Acc) ->
    mask(Rest, string, <<Acc/binary, "\n">>);
mask(<<_, Rest/binary>>, State, Acc) when State =:= comment; State =:= string ->
    mask(Rest, State, <<Acc/binary, " ">>);
mask(<<C, Rest/binary>>, code, Acc) ->
    mask(Rest, code, <<Acc/binary, C>>).

-doc """
Compile order of `Modules` (name → imports): every module after the uploaded
modules it imports, alphabetical where the order is free. `Known` says whether
a module that is not uploaded can be imported (built into the compiler or
shipped with OTP). The rest is blocked: `{missing, Names}` for imports that
are nowhere, `{dependency, Names}` for uploaded imports that are blocked
themselves (or part of a cycle).
""".
-spec order(#{name() => [name()]}, fun((name()) -> boolean())) ->
          {[name()], #{name() => blocked()}}.
order(Modules, Known) ->
    Missing = #{M => Ms || M := Imports <- Modules,
                           Ms <- [[I || I <- Imports, not is_map_key(I, Modules), not Known(I)]],
                           Ms =/= []},
    Deps = #{M => [I || I <- Imports, is_map_key(I, Modules), I =/= M] || M := Imports <- Modules},
    Candidates = lists:sort([M || M := _ <- Modules, not is_map_key(M, Missing)]),
    Ordered = kahn(Candidates, Deps, sets:new([{version, 2}]), []),
    Done = sets:from_list(Ordered, [{version, 2}]),
    Blocked = maps:merge(
                #{M => {dependency, [D || D <- maps:get(M, Deps), not sets:is_element(D, Done)]}
                  || M <- Candidates, not sets:is_element(M, Done)},
                #{M => {missing, Ms} || M := Ms <- Missing}),
    {Ordered, Blocked}.

kahn(Pending, Deps, Done, Acc) ->
    case [M || M <- Pending, lists:all(fun(D) -> sets:is_element(D, Done) end, maps:get(M, Deps))] of
        [] ->
            lists:reverse(Acc);
        [Next | _] ->
            kahn(Pending -- [Next], Deps, sets:add_element(Next, Done), [Next | Acc])
    end.

-doc """
Cache key of a compiled module: hex SHA-256 over the compiler version, the
source and the keys of its uploaded imports (`DepKeys`, any order).
""".
-spec cache_key(binary(), binary(), [{name(), binary()}]) -> binary().
cache_key(CompilerVsn, Source, DepKeys) ->
    Data = term_to_binary({CompilerVsn, Source, lists:sort(DepKeys)}),
    binary:encode_hex(crypto:hash(sha256, Data), lowercase).
