-module(s2i_transform_tests).
-include_lib("eunit/include/eunit.hrl").

-define(LIN(Scale, Offset), #{kind => linear, scale => Scale, offset => Offset}).

conv(T, V) -> s2i_transform:convert(T, V, 0, undefined).

%%% convert

linear_test_() ->
    [?_assertEqual({ok, 6.0, undefined}, conv(?LIN(0.5, 1), {integer, 10})),
     ?_assertEqual({ok, 6.0, undefined}, conv(?LIN(0.5, 1), {gauge32, 10})),
     ?_assertEqual({ok, 12.0, undefined}, conv(?LIN(1, 0), {timeticks, 12})),
     ?_assertEqual({ok, 1.0e19, undefined}, conv(?LIN(1, 0), {counter64, 10000000000000000000})),
     ?_assertEqual({invalid, type_mismatch, undefined}, conv(?LIN(1, 0), {octet_string, <<"12">>}))].

snmp_exceptions_are_invalid_test_() ->
    [?_assertEqual({invalid, E, undefined}, conv(?LIN(1, 0), E))
     || E <- [no_such_object, no_such_instance, end_of_mib_view]].

enum_test_() ->
    M = #{kind => enum, map => #{<<"1">> => true, <<"2">> => false}},
    [?_assertEqual({ok, true, undefined}, conv(M, {integer, 1})),
     ?_assertEqual({ok, false, undefined}, conv(M, {integer, 2})),
     ?_assertEqual({invalid, unmapped, undefined}, conv(M, {integer, 7})),
     ?_assertEqual({ok, false, undefined}, conv(M#{default => false}, {integer, 7})),
     ?_assertEqual({ok, -3, undefined}, conv(#{kind => enum, map => #{<<"-1">> => -3}}, {integer, -1})),
     ?_assertEqual({invalid, type_mismatch, undefined}, conv(M, {octet_string, <<1>>}))].

bit_test_() ->
    B = fun(N) -> #{kind => bit, bit => N} end,
    [?_assertEqual({ok, true, undefined}, conv(B(2), {integer, 2#100})),
     ?_assertEqual({ok, false, undefined}, conv(B(1), {integer, 2#100})),
     %% SNMP BITS: bit 0 is the most significant bit of the first octet
     ?_assertEqual({ok, true, undefined}, conv(B(1), {octet_string, <<2#01000000>>})),
     ?_assertEqual({ok, true, undefined}, conv(B(8), {octet_string, <<0, 2#10000000>>})),
     ?_assertEqual({ok, false, undefined}, conv(B(0), {octet_string, <<2#01111111>>})),
     %% trailing zero octets may be omitted by the agent
     ?_assertEqual({ok, false, undefined}, conv(B(20), {octet_string, <<255>>}))].

threshold_test_() ->
    T = fun(Op, L) -> #{kind => threshold, op => Op, limit => L} end,
    [?_assertEqual({ok, true, undefined}, conv(T(gt, 50), {integer, 51})),
     ?_assertEqual({ok, false, undefined}, conv(T(gt, 50), {integer, 50})),
     ?_assertEqual({ok, true, undefined}, conv(T(ge, 50), {gauge32, 50})),
     ?_assertEqual({ok, true, undefined}, conv(T(lt, 0.5), {integer, 0})),
     ?_assertEqual({ok, true, undefined}, conv(T(le, 3), {integer, 3})),
     ?_assertEqual({ok, true, undefined}, conv(T(eq, 3.0), {integer, 3})),
     ?_assertEqual({ok, false, undefined}, conv(T(ne, 3), {integer, 3}))].

counter_test_() ->
    C = #{kind => counter},
    [?_assertEqual({ok, 5, undefined}, conv(C, {counter32, 5})),
     ?_assertEqual({ok, 1 bsl 40, undefined}, conv(C, {counter64, 1 bsl 40})),
     ?_assertEqual({invalid, type_mismatch, undefined}, conv(C, {integer, 5}))].

rate_test() ->
    R = #{kind => rate, factor => 8},
    {skip, S1} = s2i_transform:convert(R, {counter32, 100}, 1000, undefined),
    {ok, 8000.0, S2} = s2i_transform:convert(R, {counter32, 1100}, 2000, S1),
    %% 32-bit wrap
    {ok, 1600.0, S3} = s2i_transform:convert(R, {counter32, 100}, 3000, setup_prev(S2, (1 bsl 32) - 100)),
    %% no time elapsed: nothing to report, keep the previous sample
    {skip, S3} = s2i_transform:convert(R, {counter32, 200}, 3000, S3),
    %% a reset (state undefined, e.g. after a device reboot) starts over
    {skip, _} = s2i_transform:convert(R, {counter32, 5}, 4000, undefined),
    ?assertEqual({invalid, type_mismatch, S3}, s2i_transform:convert(R, {gauge32, 1}, 5000, S3)).

rate_counter64_wrap_test() ->
    R = #{kind => rate, factor => 1},
    {skip, S} = s2i_transform:convert(R, {counter64, (1 bsl 64) - 10}, 0, undefined),
    ?assertMatch({ok, 20.0, _}, s2i_transform:convert(R, {counter64, 10}, 1000, S)).

setup_prev(_State, Prev) ->
    %% replay a sample at t=2000 to put the counter just below the wrap
    {skip, S} = s2i_transform:convert(#{kind => rate, factor => 8}, {counter32, Prev}, 2000, undefined),
    S.

%%% encode

encode_states_test_() ->
    [?_assertEqual(#{value => true, quality => []}, s2i_transform:encode(m_sp_tb_1, true)),
     ?_assertEqual(#{value => false, quality => []}, s2i_transform:encode(m_sp_na_1, false)),
     ?_assertEqual(#{value => 0, quality => []}, s2i_transform:encode(m_dp_tb_1, intermediate)),
     ?_assertEqual(#{value => 1, quality => []}, s2i_transform:encode(m_dp_na_1, off)),
     ?_assertEqual(#{value => 2, quality => []}, s2i_transform:encode(m_dp_na_1, on)),
     ?_assertEqual(#{value => 3, quality => []}, s2i_transform:encode(m_dp_na_1, faulty)),
     %% enum to step position, and bit/threshold to SP via boolean
     ?_assertEqual(#{value => -5, transient => false, quality => []}, s2i_transform:encode(m_st_na_1, -5))].

encode_normalized_test_() ->
    [?_assertEqual(#{value => 16384, quality => []}, s2i_transform:encode(m_me_na_1, 0.5)),
     ?_assertEqual(#{value => -32768, quality => []}, s2i_transform:encode(m_me_td_1, -1.0)),
     ?_assertEqual(#{value => 32767, quality => [overflow]}, s2i_transform:encode(m_me_na_1, 1.0)),
     ?_assertEqual(#{value => -32768, quality => [overflow]}, s2i_transform:encode(m_me_na_1, -1.5))].

encode_scaled_test_() ->
    [?_assertEqual(#{value => 124, quality => []}, s2i_transform:encode(m_me_nb_1, 123.6)),
     ?_assertEqual(#{value => -7, quality => []}, s2i_transform:encode(m_me_te_1, -7)),
     ?_assertEqual(#{value => 32767, quality => [overflow]}, s2i_transform:encode(m_me_nb_1, 40000)),
     ?_assertEqual(#{value => -32768, quality => [overflow]}, s2i_transform:encode(m_me_nb_1, -40000.0))].

encode_float_test_() ->
    Max = 3.4028234663852886e38,
    [?_assertEqual(#{value => 1.5, quality => []}, s2i_transform:encode(m_me_nc_1, 1.5)),
     ?_assertEqual(#{value => 3.0, quality => []}, s2i_transform:encode(m_me_tf_1, 3)),
     ?_assertEqual(#{value => Max, quality => [overflow]}, s2i_transform:encode(m_me_nc_1, 1.0e39)),
     ?_assertEqual(#{value => -Max, quality => [overflow]}, s2i_transform:encode(m_me_nc_1, -1.0e39))].

encode_integrated_total_test_() ->
    %% BCR is a signed 32-bit reading; counters are reported modulo 2^31
    [?_assertEqual(#{value => 5, quality => []}, s2i_transform:encode(m_it_na_1, 5)),
     ?_assertEqual(#{value => 5, quality => []}, s2i_transform:encode(m_it_tb_1, (1 bsl 31) + 5))].

%%% deadband

deadband_test_() ->
    Abs = #{kind => absolute, value => 0.5},
    Pct = #{kind => percent, value => 10},
    [?_assert(s2i_transform:deadband(undefined, 1.0, 1.0)),
     ?_assert(s2i_transform:deadband(Abs, 1.0, undefined)),
     ?_assertNot(s2i_transform:deadband(Abs, 10.4, 10.0)),
     ?_assert(s2i_transform:deadband(Abs, 10.5, 10.0)),
     ?_assert(s2i_transform:deadband(Abs, 9.5, 10.0)),
     ?_assertNot(s2i_transform:deadband(Pct, 109.0, 100.0)),
     ?_assert(s2i_transform:deadband(Pct, 110.0, 100.0)),
     ?_assertNot(s2i_transform:deadband(Pct, -105.0, -100.0)),
     ?_assertNot(s2i_transform:deadband(Pct, 0.0, 0.0)),
     ?_assert(s2i_transform:deadband(Pct, 0.1, 0.0))].
