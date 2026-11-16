-module(s2i_secret).
-moduledoc """
Encryption of stored secrets (SNMP communities, USM passwords).

Secrets are stored as text envelopes

```text
enc:v1:<key id, 8 hex>:<base64(iv[12] | tag[16] | ciphertext)>
```

using AES-256-GCM with a random IV per value. The key id (derived from the
key) detects ciphertext from another installation's key and leaves room for
key rotation. Envelopes are JSON-safe: staged config, versions and exports
only ever contain ciphertext. Plaintext is produced by `open/1` where it is
needed (the SNMP manager).

The key is read from a file (`s2i_core` env `secret_key_file`) holding the
base64-encoded 32-byte key (`openssl rand -base64 32`). The file must not be
accessible by group or others. If it does not exist, a new key is generated
with mode 0600. Without that file the stored secrets cannot be recovered, so
it has to be backed up separately from the Mnesia data.
""".

-export([load/1, unload/0, seal/1, open/1, is_sealed/1, parse/1,
         seal_entity/3, check_config/1]).

-include_lib("kernel/include/file.hrl").

-define(KEY, {?MODULE, key}).
-define(PREFIX, "enc:v1:").
-define(AAD, <<"s2i-secret-v1">>).
-define(IV_LEN, 12).
-define(TAG_LEN, 16).

%% Secret fields per entity kind, as paths into the canonical entity.
-define(FIELDS, #{device => [[snmp, community], [snmp, auth_password], [snmp, priv_password]]}).

-type envelope() :: binary().
-type open_error() :: wrong_key | corrupt.
-export_type([envelope/0]).

%%% ===========================================================================
%%% Key
%%% ===========================================================================

-doc "Load (or create) the key file and make the key available to this node.".
-spec load(file:filename_all()) ->
          ok | {error, {insecure_permissions, file:filename_all(), integer()}
                     | {invalid_key, file:filename_all()} | {atom(), term()}}.
load(Path) ->
    case read_key(Path) of
        {ok, Key} ->
            persistent_term:put(?KEY, {key_id(Key), Key}),
            ok;
        {error, enoent} ->
            case create_key(Path) of
                ok ->
                    logger:warning("Generated new secret key ~ts. Back it up: stored "
                                   "SNMP secrets cannot be decrypted without it.", [Path]),
                    load(Path);
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

-spec unload() -> ok.
unload() ->
    _ = persistent_term:erase(?KEY),
    ok.

read_key(Path) ->
    case file:read_file_info(Path) of
        {ok, #file_info{mode = Mode}} when Mode band 8#077 =/= 0 ->
            {error, {insecure_permissions, Path, Mode band 8#777}};
        {ok, _} ->
            case file:read_file(Path) of
                {ok, Text} ->
                    try base64:decode(string:trim(Text)) of
                        <<Key:32/binary>> -> {ok, Key};
                        _ -> {error, {invalid_key, Path}}
                    catch
                        error:_ -> {error, {invalid_key, Path}}
                    end;
                {error, Reason} ->
                    {error, {Reason, Path}}
            end;
        {error, enoent} ->
            {error, enoent};
        {error, Reason} ->
            {error, {Reason, Path}}
    end.

%% Exclusive create + chmod before writing, so the key is never readable by others.
create_key(Path) ->
    ok = filelib:ensure_dir(Path),
    case file:open(Path, [write, exclusive, binary]) of
        {ok, Fd} ->
            try
                ok = file:change_mode(Path, 8#600),
                ok = file:write(Fd, [base64:encode(crypto:strong_rand_bytes(32)), $\n]),
                ok = file:sync(Fd)
            after
                file:close(Fd)
            end;
        {error, Reason} ->
            {error, {Reason, Path}}
    end.

key_id(Key) ->
    <<Id:4/binary, _/binary>> = crypto:hash(sha256, [<<"s2i-key-id">>, Key]),
    binary:encode_hex(Id, lowercase).

key() ->
    case persistent_term:get(?KEY, undefined) of
        undefined -> error(no_secret_key);
        K -> K
    end.

%%% ===========================================================================
%%% Values
%%% ===========================================================================

-spec seal(binary()) -> envelope().
seal(Plain) when is_binary(Plain) ->
    {KeyId, Key} = key(),
    Iv = crypto:strong_rand_bytes(?IV_LEN),
    {Ct, Tag} = crypto:crypto_one_time_aead(aes_256_gcm, Key, Iv, Plain, ?AAD, ?TAG_LEN, true),
    <<?PREFIX, KeyId/binary, ":", (base64:encode(<<Iv/binary, Tag/binary, Ct/binary>>))/binary>>.

-spec open(envelope()) -> {ok, binary()} | {error, open_error()}.
open(Envelope) ->
    case parse(Envelope) of
        {ok, KeyId, <<Iv:?IV_LEN/binary, Tag:?TAG_LEN/binary, Ct/binary>>} ->
            case key() of
                {KeyId, Key} ->
                    case crypto:crypto_one_time_aead(aes_256_gcm, Key, Iv, Ct, ?AAD, Tag, false) of
                        error -> {error, corrupt};
                        Plain -> {ok, Plain}
                    end;
                _ ->
                    {error, wrong_key}
            end;
        error ->
            {error, corrupt}
    end.

-doc "Whether a value claims to be an envelope (it may still be malformed).".
-spec is_sealed(term()) -> boolean().
is_sealed(<<"enc:", _/binary>>) -> true;
is_sealed(_) -> false.

-doc "Structure of an envelope; no key needed.".
-spec parse(binary()) -> {ok, binary(), binary()} | error.
parse(<<?PREFIX, KeyId:8/binary, ":", B64/binary>>) when B64 =/= <<>> ->
    try {is_hex(KeyId), base64:decode(B64)} of
        {true, Raw} when byte_size(Raw) >= ?IV_LEN + ?TAG_LEN -> {ok, KeyId, Raw};
        _ -> error
    catch
        error:_ -> error
    end;
parse(_) ->
    error.

is_hex(B) -> lists:all(fun(C) -> (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) end,
                       binary_to_list(B)).

%%% ===========================================================================
%%% Entities
%%% ===========================================================================

-doc """
Seal the secret fields of a canonical entity. Plaintext equal to the secret in
`Old` (the currently stored entity) keeps the old ciphertext, so re-saving an
unchanged entity is not a change. Envelopes must decrypt with the loaded key.
""".
-spec seal_entity(s2i_schema:kind(), map(), map() | undefined) ->
          {ok, map()} | {error, [s2i_schema:error()]}.
seal_entity(Kind, Entity, Old) ->
    {Sealed, Errors} =
        lists:foldl(
          fun(Path, {E, Errs}) ->
                  case get_path(Path, E) of
                      error ->
                          {E, Errs};
                      {ok, V} ->
                          case seal_value(V, get_path(Path, old_or_empty(Old))) of
                              {ok, S} -> {put_path(Path, S, E), Errs};
                              {error, R} -> {E, [#{path => Path, error => R} | Errs]}
                          end
                  end
          end, {Entity, []}, maps:get(Kind, ?FIELDS, [])),
    case Errors of
        [] -> {ok, Sealed};
        _ -> {error, lists:reverse(Errors)}
    end.

seal_value(V, OldV) ->
    case is_sealed(V) of
        true ->
            case open(V) of
                {ok, _} -> {ok, V};
                Error -> Error
            end;
        false ->
            case OldV of
                {ok, Old} ->
                    case open(Old) of
                        {ok, V} -> {ok, Old};
                        _ -> {ok, seal(V)}
                    end;
                error ->
                    {ok, seal(V)}
            end
    end.

-doc "Secrets in a configuration that do not decrypt with the loaded key.".
-spec check_config(map()) -> [s2i_schema:error()].
check_config(Config) ->
    [#{path => [Section, Name | Path], error => R}
     || {Section, Kind} <- s2i_validate:sections(),
        Name := Entity <- maps:iterator(maps:get(Section, Config, #{}), ordered),
        Path <- maps:get(Kind, ?FIELDS, []),
        {ok, V} <- [get_path(Path, Entity)],
        {error, R} <- [open(V)]].

old_or_empty(undefined) -> #{};
old_or_empty(Old) -> Old.

get_path([K], M) when is_map(M) -> maps:find(K, M);
get_path([K | Rest], M) when is_map(M) ->
    case maps:find(K, M) of
        {ok, Sub} -> get_path(Rest, Sub);
        error -> error
    end;
get_path(_, _) -> error.

put_path([K], V, M) -> M#{K => V};
put_path([K | Rest], V, M) -> M#{K => put_path(Rest, V, maps:get(K, M))}.
