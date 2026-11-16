-module(s2i_transform_prop_tests).
-moduledoc "PropEr properties for s2i_transform (run through eunit).".
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(N, 2000).

props_test_() ->
    [{atom_to_list(P), ?_assert(proper:quickcheck(?MODULE:P(), [{numtests, ?N}, {to_file, user}]))}
     || P <- [prop_rate_survives_wrap, prop_scaled_in_range, prop_normalized_in_range,
              prop_float_in_range, prop_integrated_total_in_range, prop_enum_is_total]].

%% Wrapping counters: the rate equals the true increment for any start value.
prop_rate_survives_wrap() ->
    ?FORALL({Bits, Start, Delta, Dt}, {oneof([32, 64]), non_neg_integer(), non_neg_integer(), range(1, 1000000)},
            begin
                Mod = 1 bsl Bits,
                Type = case Bits of 32 -> counter32; 64 -> counter64 end,
                S0 = Start rem Mod,
                D = Delta rem Mod,
                R = #{kind => rate, factor => 1},
                {skip, St} = s2i_transform:convert(R, {Type, S0}, 0, undefined),
                {ok, Rate, _} = s2i_transform:convert(R, {Type, (S0 + D) rem Mod}, Dt, St),
                abs(Rate - D * 1000 / Dt) =< 1.0e-9 * max(1.0, abs(Rate))
            end).

%% Encoded values always fit the wire format; overflow iff clamped.
prop_scaled_in_range() ->
    ?FORALL(X, number(),
            begin
                #{value := V, quality := Q} = s2i_transform:encode(m_me_nb_1, X),
                R = round(X),
                is_integer(V) andalso V >= -32768 andalso V =< 32767 andalso
                    (lists:member(overflow, Q) =:= (R < -32768 orelse R > 32767))
            end).

prop_normalized_in_range() ->
    ?FORALL(X, oneof([float(-2.0, 2.0), number()]),
            begin
                #{value := V, quality := Q} = s2i_transform:encode(m_me_na_1, X),
                is_integer(V) andalso V >= -32768 andalso V =< 32767 andalso
                    (lists:member(overflow, Q) =:= (X < -1 orelse X >= 1))
            end).

prop_float_in_range() ->
    ?FORALL(X, oneof([float(), integer(), exactly(1.0e300), exactly(-1.0e300)]),
            begin
                #{value := V} = s2i_transform:encode(m_me_nc_1, X),
                is_float(V) andalso abs(V) =< 3.4028234663852886e38
            end).

prop_integrated_total_in_range() ->
    ?FORALL(X, non_neg_integer(),
            begin
                #{value := V} = s2i_transform:encode(m_it_na_1, X * 7919),
                V >= 0 andalso V < (1 bsl 31)
            end).

%% Any integer input gives a state or `unmapped`, never a crash.
prop_enum_is_total() ->
    ?FORALL(I, integer(),
            case s2i_transform:convert(#{kind => enum, map => #{<<"1">> => true}}, {integer, I}, 0, undefined) of
                {ok, true, _} -> I =:= 1;
                {invalid, unmapped, _} -> I =/= 1
            end).
