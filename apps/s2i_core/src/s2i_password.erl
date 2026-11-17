-module(s2i_password).
-moduledoc """
Password hashes for web users: PBKDF2-HMAC-SHA256 with a random 16-byte salt
per user and 32-byte output (docs/DESIGN.md §9.2).

A hash is a JSON-safe map
`#{alg => pbkdf2_sha256, iterations, salt, hash}` (salt and hash base64),
so the iteration count can be raised later without invalidating stored
hashes: `needs_rehash/2` tells when a hash should be renewed on the next
successful login.

`verify/2` compares in constant time. `dummy_verify/1` costs as much as a
real verification, for unknown user names (no user enumeration by timing).
""".

-export([hash/2, verify/2, dummy_verify/1, needs_rehash/2, check_policy/1]).
-export_type([hash/0]).

-type hash() :: #{alg := pbkdf2_sha256, iterations := pos_integer(),
                  salt := binary(), hash := binary()}.

-define(SALT_LEN, 16).
-define(KEY_LEN, 32).
-define(MIN_LEN, 8).
-define(MAX_LEN, 1024).

-spec hash(binary(), pos_integer()) -> hash().
hash(Password, Iterations) when is_binary(Password), is_integer(Iterations), Iterations > 0 ->
    Salt = crypto:strong_rand_bytes(?SALT_LEN),
    #{alg => pbkdf2_sha256, iterations => Iterations,
      salt => base64:encode(Salt), hash => base64:encode(derive(Password, Salt, Iterations))}.

-spec verify(binary(), hash()) -> boolean().
verify(Password, #{alg := pbkdf2_sha256, iterations := N, salt := Salt, hash := Hash})
  when is_binary(Password) ->
    Expected = base64:decode(Hash),
    crypto:hash_equals(Expected, derive(Password, base64:decode(Salt), N));
verify(_Password, _Hash) ->
    false.

-spec dummy_verify(pos_integer()) -> false.
dummy_verify(Iterations) ->
    _ = derive(<<"dummy">>, <<0:(?SALT_LEN * 8)>>, Iterations),
    false.

-doc "Whether a stored hash uses fewer iterations than currently configured.".
-spec needs_rehash(hash(), pos_integer()) -> boolean().
needs_rehash(#{iterations := N}, Iterations) -> N < Iterations.

-doc "Length rules for a new password (8 to 1024 bytes, valid UTF-8).".
-spec check_policy(term()) -> ok | {error, too_short | too_long | invalid_type}.
check_policy(P) when is_binary(P) ->
    case unicode:characters_to_binary(P) of
        P when byte_size(P) < ?MIN_LEN -> {error, too_short};
        P when byte_size(P) > ?MAX_LEN -> {error, too_long};
        P -> ok;
        _ -> {error, invalid_type}
    end;
check_policy(_) ->
    {error, invalid_type}.

derive(Password, Salt, Iterations) ->
    crypto:pbkdf2_hmac(sha256, Password, Salt, Iterations, ?KEY_LEN).
