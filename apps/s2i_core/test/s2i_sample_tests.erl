-module(s2i_sample_tests).
-include_lib("eunit/include/eunit.hrl").

-define(S, <<"scada">>).
-define(CTX(Now), #{now => Now, ts => 1700000000000 + Now}).

route(Ioa, Type, Transform) ->
    #{datapoint => <<"dp">>, server => ?S, coa => 1, ioa => Ioa, type => Type,
      transform => Transform}.

temp() -> route(10, m_me_tf_1, #{kind => linear, scale => 0.1, offset => 0}).
temp_db() -> (temp())#{deadband => #{kind => absolute, value => 1.0}}.
link() -> route(20, m_sp_na_1, #{kind => enum, map => #{<<"1">> => true, <<"2">> => false}}).
rate() -> route(30, m_me_nc_1, #{kind => rate, factor => 8}).
%% not accepted by the schema; the sample step must still not crash on it
misconfigured() -> route(40, m_sp_na_1, #{kind => enum, map => #{<<"1">> => true, <<"2">> => on}}).

apply1(Route, Value, Now, States) ->
    s2i_sample:apply([Route], Value, ?CTX(Now), States).

%%% first value, timestamps

first_value_is_published_with_timestamp_test() ->
    {W, St} = apply1(temp(), {integer, 215}, 0, #{}),
    ?assertMatch([{?S, {1, 10}, #{type := m_me_tf_1, quality := [], ts := 1700000000000}}], W),
    [{_, _, #{value := V}}] = W,
    ?assert(abs(V - 21.5) < 1.0e-9),
    ?assertMatch(#{{?S, 1, 10} := #{valid := true}}, St).

untagged_type_has_no_timestamp_test() ->
    {[{?S, {1, 20}, Spec}], _} = apply1(link(), {integer, 1}, 0, #{}),
    ?assertEqual(#{type => m_sp_na_1, value => true, quality => []}, Spec).

%%% only changes are sent

unchanged_status_is_not_republished_test() ->
    {_, St1} = apply1(link(), {integer, 1}, 0, #{}),
    ?assertMatch({[], _}, apply1(link(), {integer, 1}, 1000, St1)),
    ?assertMatch({[{?S, {1, 20}, #{value := false}}], _}, apply1(link(), {integer, 2}, 2000, St1)).

unchanged_measurement_without_deadband_is_not_republished_test() ->
    {_, St1} = apply1(temp(), {integer, 215}, 0, #{}),
    ?assertMatch({[], _}, apply1(temp(), {integer, 215}, 1000, St1)),
    ?assertMatch({[_], _}, apply1(temp(), {integer, 216}, 1000, St1)).

deadband_compares_with_last_sent_value_test() ->
    {_, St1} = apply1(temp_db(), {integer, 200}, 0, #{}),        % 20.0 sent
    {W2, St2} = apply1(temp_db(), {integer, 205}, 1000, St1),    % 20.5: below band
    ?assertEqual([], W2),
    {W3, _} = apply1(temp_db(), {integer, 210}, 2000, St2),      % 21.0 vs 20.0: sent
    ?assertMatch([{_, _, #{value := _}}], W3).

%%% invalid input

invalid_value_marks_point_invalid_once_test() ->
    {_, St1} = apply1(temp(), {integer, 215}, 0, #{}),
    {W2, St2} = apply1(temp(), no_such_instance, 1000, St1),
    ?assertEqual([{?S, {1, 10}, invalid}], W2),
    ?assertMatch({[], _}, apply1(temp(), no_such_instance, 2000, St2)),
    %% the next good value is sent even if it equals the last one
    ?assertMatch({[{?S, {1, 10}, #{quality := []}}], _}, apply1(temp(), {integer, 215}, 3000, St2)).

invalid_before_first_value_sends_nothing_test() ->
    %% the point is still seeded invalid
    ?assertMatch({[], #{{?S, 1, 10} := #{valid := false}}}, apply1(temp(), no_such_object, 0, #{})).

unencodable_value_is_invalid_not_a_crash_test() ->
    {_, St1} = apply1(misconfigured(), {integer, 1}, 0, #{}),
    ?assertMatch({[{?S, {1, 40}, invalid}], _}, apply1(misconfigured(), {integer, 2}, 1000, St1)).

overflow_is_flagged_test() ->
    R = route(50, m_me_nb_1, #{kind => linear, scale => 1, offset => 0}),
    ?assertMatch({[{?S, {1, 50}, #{value := 32767, quality := [overflow]}}], _},
                 apply1(R, {integer, 100000}, 0, #{})).

%%% rate: first sample only primes the state

rate_needs_two_samples_test() ->
    {W1, St1} = apply1(rate(), {counter32, 1000}, 0, #{}),
    ?assertEqual([], W1),
    {[{?S, {1, 30}, #{value := V}}], _} = apply1(rate(), {counter32, 2000}, 1000, St1),
    ?assert(abs(V - 8000.0) < 1.0e-9).

reset_forgets_rate_state_but_keeps_last_value_test() ->
    {_, St1} = apply1(rate(), {counter32, 1000}, 0, #{}),
    {_, St2} = apply1(rate(), {counter32, 2000}, 1000, St1),
    St3 = s2i_sample:reset(St2),
    %% after a reboot the counter restarts: no bogus huge delta, just re-prime
    ?assertMatch({[], _}, apply1(rate(), {counter32, 5}, 2000, St3)).

%%% several mappings of one OID

all_routes_of_an_oid_are_applied_test() ->
    R1 = route(60, m_me_nc_1, #{kind => linear, scale => 1, offset => 0}),
    R2 = (route(61, m_sp_na_1, #{kind => threshold, op => gt, limit => 50}))#{server => <<"other">>},
    {W, _} = s2i_sample:apply([R1, R2], {gauge32, 70}, ?CTX(0), #{}),
    ?assertMatch([{?S, {1, 60}, #{value := 70.0}}, {<<"other">>, {1, 61}, #{value := true}}], W).

%%% device down

invalidate_sends_invalid_for_valid_points_only_test() ->
    {_, St1} = apply1(temp(), {integer, 215}, 0, #{}),
    {W, St2} = s2i_sample:invalidate([temp(), link()], St1),
    ?assertEqual([{?S, {1, 10}, invalid}], W),
    ?assertMatch({[], _}, s2i_sample:invalidate([temp(), link()], St2)),
    %% recovery republishes the unchanged value
    ?assertMatch({[{?S, {1, 10}, #{quality := []}}], _}, apply1(temp(), {integer, 215}, 1000, St2)).

group_writes_by_server_test() ->
    W = [{<<"a">>, {1, 1}, x}, {<<"b">>, {1, 2}, invalid}, {<<"a">>, {1, 3}, invalid}],
    ?assertEqual(#{<<"a">> => {[{{1, 1}, x}], [{1, 3}]}, <<"b">> => {[], [{1, 2}]}},
                 s2i_sample:by_server(W)).
