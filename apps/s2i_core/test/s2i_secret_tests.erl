-module(s2i_secret_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

%%% fixtures

tmp_dir() ->
    Dir = filename:join([os:getenv("TMPDIR", "/tmp"), "s2i_secret_tests",
                         integer_to_list(erlang:unique_integer([positive]))]),
    ok = filelib:ensure_path(Dir),
    Dir.

with_key(Fun) ->
    Path = filename:join(tmp_dir(), "secret.key"),
    ok = s2i_secret:load(Path),
    try Fun(Path) after s2i_secret:unload() end.

v3() ->
    #{version => v3, user => <<"u">>, sec_level => auth_priv,
      auth_protocol => sha256, auth_password => <<"authpass1">>,
      priv_protocol => aes, priv_password => <<"privpass1">>}.

%%% key file

missing_key_file_is_generated_owner_only_test() ->
    Path = filename:join([tmp_dir(), "sub", "secret.key"]),
    ok = s2i_secret:load(Path),
    s2i_secret:unload(),
    {ok, #file_info{mode = Mode}} = file:read_file_info(Path),
    ?assertEqual(0, Mode band 8#077),
    {ok, Text} = file:read_file(Path),
    ?assertEqual(32, byte_size(base64:decode(string:trim(Text)))),
    %% loading again uses the same key
    ok = s2i_secret:load(Path),
    Sealed = s2i_secret:seal(<<"x">>),
    s2i_secret:unload(),
    ok = s2i_secret:load(Path),
    ?assertEqual({ok, <<"x">>}, s2i_secret:open(Sealed)),
    s2i_secret:unload().

group_or_world_readable_key_is_refused_test() ->
    Path = filename:join(tmp_dir(), "secret.key"),
    ok = s2i_secret:load(Path),
    s2i_secret:unload(),
    ok = file:change_mode(Path, 8#640),
    ?assertEqual({error, {insecure_permissions, Path, 8#640}}, s2i_secret:load(Path)).

invalid_key_file_is_refused_test() ->
    Dir = tmp_dir(),
    Short = filename:join(Dir, "short.key"),
    ok = file:write_file(Short, base64:encode(<<1, 2, 3>>)),
    ok = file:change_mode(Short, 8#600),
    ?assertEqual({error, {invalid_key, Short}}, s2i_secret:load(Short)),
    Junk = filename:join(Dir, "junk.key"),
    ok = file:write_file(Junk, <<"not base64 !!!">>),
    ok = file:change_mode(Junk, 8#600),
    ?assertEqual({error, {invalid_key, Junk}}, s2i_secret:load(Junk)).

openssl_style_key_with_newline_is_accepted_test() ->
    Path = filename:join(tmp_dir(), "secret.key"),
    ok = file:write_file(Path, [base64:encode(crypto:strong_rand_bytes(32)), "\n"]),
    ok = file:change_mode(Path, 8#400),
    ?assertEqual(ok, s2i_secret:load(Path)),
    s2i_secret:unload().

no_key_loaded_test() ->
    s2i_secret:unload(),
    ?assertError(no_secret_key, s2i_secret:seal(<<"x">>)).

%%% seal / open

roundtrip_test() ->
    with_key(fun(_) ->
        S = s2i_secret:seal(<<"public">>),
        ?assert(s2i_secret:is_sealed(S)),
        ?assertNot(s2i_secret:is_sealed(<<"public">>)),
        ?assertEqual(nomatch, binary:match(S, <<"public">>)),
        ?assertEqual({ok, <<"public">>}, s2i_secret:open(S))
    end).

random_iv_test() ->
    with_key(fun(_) ->
        ?assertNotEqual(s2i_secret:seal(<<"public">>), s2i_secret:seal(<<"public">>))
    end).

envelope_is_json_safe_text_test() ->
    with_key(fun(_) ->
        <<"enc:v1:", _/binary>> = S = s2i_secret:seal(<<"public">>),
        ?assertEqual(S, json:decode(iolist_to_binary(json:encode(S))))
    end).

other_key_is_detected_test() ->
    S = with_key(fun(_) -> s2i_secret:seal(<<"public">>) end),
    with_key(fun(_) -> ?assertEqual({error, wrong_key}, s2i_secret:open(S)) end).

tampering_is_detected_test() ->
    with_key(fun(_) ->
        <<"enc:v1:", KeyId:8/binary, ":", B64/binary>> = s2i_secret:seal(<<"public">>),
        <<First, Rest/binary>> = base64:decode(B64),
        Bad = <<"enc:v1:", KeyId/binary, ":", (base64:encode(<<(First bxor 1), Rest/binary>>))/binary>>,
        ?assertEqual({error, corrupt}, s2i_secret:open(Bad)),
        ?assertEqual({error, corrupt}, s2i_secret:open(<<"enc:v1:", KeyId/binary, ":%%">>)),
        ?assertEqual({error, corrupt}, s2i_secret:open(<<"enc:v1:short">>))
    end).

%%% entities

device_secrets_are_sealed_test() ->
    with_key(fun(_) ->
        {ok, #{snmp := #{community := C}}} =
            s2i_secret:seal_entity(device, #{snmp => #{version => v2c, community => <<"public">>}}, undefined),
        ?assertEqual({ok, <<"public">>}, s2i_secret:open(C)),
        {ok, #{snmp := #{auth_password := A, priv_password := P, user := <<"u">>}}} =
            s2i_secret:seal_entity(device, #{snmp => v3()}, undefined),
        ?assertEqual({ok, <<"authpass1">>}, s2i_secret:open(A)),
        ?assertEqual({ok, <<"privpass1">>}, s2i_secret:open(P))
    end).

unchanged_secret_keeps_its_ciphertext_test() ->
    with_key(fun(_) ->
        {ok, Old} = s2i_secret:seal_entity(device, #{snmp => v3()}, undefined),
        {ok, New} = s2i_secret:seal_entity(device, #{snmp => v3()}, Old),
        ?assertEqual(Old, New),
        {ok, Changed} = s2i_secret:seal_entity(
                          device, #{snmp => (v3())#{priv_password => <<"privpass2">>}}, Old),
        ?assertEqual(maps:get(auth_password, maps:get(snmp, Old)),
                     maps:get(auth_password, maps:get(snmp, Changed))),
        ?assertNotEqual(maps:get(priv_password, maps:get(snmp, Old)),
                        maps:get(priv_password, maps:get(snmp, Changed)))
    end).

sealed_input_passes_through_test() ->
    with_key(fun(_) ->
        {ok, Sealed} = s2i_secret:seal_entity(device, #{snmp => v3()}, undefined),
        ?assertEqual({ok, Sealed}, s2i_secret:seal_entity(device, Sealed, undefined))
    end).

foreign_ciphertext_is_rejected_test() ->
    Foreign = with_key(fun(_) -> s2i_secret:seal(<<"public">>) end),
    with_key(fun(_) ->
        Dev = #{snmp => #{version => v2c, community => Foreign}},
        ?assertEqual({error, [#{path => [snmp, community], error => wrong_key}]},
                     s2i_secret:seal_entity(device, Dev, undefined)),
        ?assertEqual([#{path => [devices, <<"d">>, snmp, community], error => wrong_key}],
                     s2i_secret:check_config(#{devices => #{<<"d">> => Dev}}))
    end).

other_kinds_are_untouched_test() ->
    ?assertEqual({ok, #{name => <<"s">>}}, s2i_secret:seal_entity(server, #{name => <<"s">>}, undefined)).

