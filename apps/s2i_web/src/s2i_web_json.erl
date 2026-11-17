-module(s2i_web_json).
-moduledoc """
JSON conversion for the REST API (pure).

- `encode/1`: any term to JSON. Canonical config entities, audit entries and
  schema errors are JSON-safe already; anything else (tuples, pids, non-UTF-8
  binaries in status maps) is rendered as a string instead of crashing.
- `varbind/1`: an snmpm varbind as `#{oid, type, value}`; octet strings are
  text when they are printable UTF-8, otherwise `null` with a `hex` field.
- `parse_oid/1`: dotted numeric OID (optional leading dot) to a list.
""".

-export([encode/1, sanitize/1, varbind/1, oid/1, parse_oid/1]).

-spec encode(term()) -> binary().
encode(Term) ->
    iolist_to_binary(json:encode(sanitize(Term))).

-doc "The term with everything JSON cannot represent turned into strings.".
-spec sanitize(term()) -> term().
sanitize(M) when is_map(M) ->
    #{key(K) => sanitize(V) || K := V <- M};
sanitize(L) when is_list(L) ->
    [sanitize(E) || E <- L];
sanitize(B) when is_binary(B) ->
    case unicode:characters_to_binary(B) of
        B -> B;
        _ -> base64:encode(B)
    end;
sanitize(A) when is_atom(A) -> A;
sanitize(N) when is_number(N) -> N;
sanitize(T) ->
    iolist_to_binary(io_lib:format("~0p", [T])).

key(K) when is_binary(K) -> sanitize(K);
key(K) when is_atom(K); is_integer(K) -> K;
key(K) -> iolist_to_binary(io_lib:format("~0p", [K])).

-spec varbind(tuple()) -> map().
varbind({varbind, Oid, Type, Value, _Index}) ->
    maps:merge(#{oid => oid(Oid), type => Type}, value(Type, Value)).

value('OCTET STRING', V) -> octets(bytes(V));
value('BITS', V) -> octets(bytes(V));
value('Opaque', V) -> octets(bytes(V));
value('IpAddress', [_, _, _, _] = Ip) -> #{value => list_to_binary(inet:ntoa(list_to_tuple(Ip)))};
value('OBJECT IDENTIFIER', V) -> #{value => oid(V)};
value('NULL', V) when is_atom(V) -> #{value => V};       % noSuchObject, endOfMibView, ...
value(_Type, V) when is_integer(V) -> #{value => V};
value(_Type, V) -> #{value => sanitize(V)}.

octets(B) ->
    Hex = binary:encode_hex(B, lowercase),
    case unicode:characters_to_binary(B) of
        B ->
            case io_lib:printable_unicode_list(unicode:characters_to_list(B)) of
                true -> #{value => B, hex => Hex};
                false -> #{value => null, hex => Hex}
            end;
        _ ->
            #{value => null, hex => Hex}
    end.

bytes(B) when is_binary(B) -> B;
bytes(L) when is_list(L) -> list_to_binary(L).

-spec oid([non_neg_integer()]) -> binary().
oid(Oid) ->
    iolist_to_binary(lists:join($., [integer_to_binary(I) || I <- Oid])).

-spec parse_oid(term()) -> {ok, [non_neg_integer()]} | error.
parse_oid(<<".", Rest/binary>>) ->
    parse_oid(Rest);
parse_oid(B) when is_binary(B), B =/= <<>> ->
    try [binary_to_integer(P) || P <- binary:split(B, <<".">>, [global])] of
        [_, _ | _] = Oid ->
            case lists:all(fun(I) -> I >= 0 andalso I =< 4294967295 end, Oid) of
                true -> {ok, Oid};
                false -> error
            end;
        _ ->
            error
    catch
        error:badarg -> error
    end;
parse_oid(_) ->
    error.
