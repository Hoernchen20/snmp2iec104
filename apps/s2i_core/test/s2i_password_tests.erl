-module(s2i_password_tests).
-include_lib("eunit/include/eunit.hrl").

-define(N, 1000).

verify_correct_password_test() ->
    H = s2i_password:hash(<<"correct horse">>, ?N),
    ?assert(s2i_password:verify(<<"correct horse">>, H)),
    ?assertNot(s2i_password:verify(<<"wrong horse">>, H)).

salt_differs_per_hash_test() ->
    A = s2i_password:hash(<<"same password">>, ?N),
    B = s2i_password:hash(<<"same password">>, ?N),
    ?assertNotEqual(maps:get(salt, A), maps:get(salt, B)),
    ?assertNotEqual(maps:get(hash, A), maps:get(hash, B)).

hash_is_json_safe_test() ->
    H = s2i_password:hash(<<"pässwörd">>, ?N),
    Decoded = json:decode(iolist_to_binary(json:encode(H))),
    Back = #{alg => pbkdf2_sha256, iterations => maps:get(<<"iterations">>, Decoded),
             salt => maps:get(<<"salt">>, Decoded), hash => maps:get(<<"hash">>, Decoded)},
    ?assert(s2i_password:verify(<<"pässwörd">>, Back)).

known_vector_test() ->
    %% well-known vector PBKDF2-HMAC-SHA256("password", "salt", c = 1, dkLen = 32)
    H = #{alg => pbkdf2_sha256, iterations => 1, salt => base64:encode(<<"salt">>),
          hash => base64:encode(binary:decode_hex(
                                  <<"120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b">>))},
    ?assert(s2i_password:verify(<<"password">>, H)).

malformed_hash_never_verifies_test() ->
    ?assertNot(s2i_password:verify(<<"x">>, #{alg => md5})),
    ?assertNot(s2i_password:verify(<<"x">>, undefined)).

dummy_verify_is_false_test() ->
    ?assertNot(s2i_password:dummy_verify(?N)).

needs_rehash_test() ->
    H = s2i_password:hash(<<"password1">>, ?N),
    ?assert(s2i_password:needs_rehash(H, ?N + 1)),
    ?assertNot(s2i_password:needs_rehash(H, ?N)).

policy_test() ->
    ?assertEqual(ok, s2i_password:check_policy(<<"12345678">>)),
    ?assertEqual({error, too_short}, s2i_password:check_policy(<<"1234567">>)),
    ?assertEqual({error, too_long}, s2i_password:check_policy(binary:copy(<<"x">>, 1025))),
    ?assertEqual({error, invalid_type}, s2i_password:check_policy(<<255, 255, 255, 255, 255, 255, 255, 255>>)),
    ?assertEqual({error, invalid_type}, s2i_password:check_policy(12345678)).
