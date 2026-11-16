-module(s2i_transform).
-moduledoc """
SNMP value → IEC 60870-5-104 point value (pure). Three steps per mapping:

1. `convert/4`: SNMP value → engineering value, using the transform
   (`linear`, `enum`, `bit`, `threshold`, `counter`, `rate`). `rate` keeps
   the previous sample in its state; pass `undefined` to reset it (counter
   discontinuity, e.g. agent reboot).
2. `deadband/3`: whether the engineering value differs enough from the last
   sent one (measured values only).
3. `encode/2`: engineering value → erl60870 point map (`value`, `quality`,
   type extras), clamping to the wire range with the `overflow` flag.

SNMP values are tagged by the poller:
`{integer | gauge32 | counter32 | counter64 | timeticks, integer()}`,
`{octet_string, binary()}`, or the exceptions `no_such_object`,
`no_such_instance`, `end_of_mib_view`. Unusable input gives
`{invalid, Reason, State}`: the caller republishes the last value with
quality `invalid`.
""".

-export([convert/4, encode/2, deadband/3]).
-export_type([snmp_value/0, state/0]).

-type snmp_value() :: {integer | gauge32 | counter32 | counter64 | timeticks, integer()}
                    | {octet_string, binary()}
                    | {atom(), term()}
                    | no_such_object | no_such_instance | end_of_mib_view.
-type state() :: undefined | {non_neg_integer(), integer()}.
-type eng() :: number() | boolean() | off | on | intermediate | faulty.

-define(INT16_MIN, -32768).
-define(INT16_MAX, 32767).
-define(FLOAT32_MAX, 3.4028234663852886e38).

%%% ===========================================================================
%%% Convert
%%% ===========================================================================

-spec convert(map(), snmp_value(), integer(), state()) ->
          {ok, eng(), state()} | {skip, state()} | {invalid, atom(), state()}.
convert(_T, Exception, _Now, State)
  when Exception =:= no_such_object; Exception =:= no_such_instance; Exception =:= end_of_mib_view ->
    {invalid, Exception, State};
convert(#{kind := linear, scale := Scale, offset := Offset}, V, _Now, State) ->
    numeric(V, State, fun(X) -> X * Scale + Offset + 0.0 end);
convert(#{kind := enum, map := Map} = T, V, _Now, State) ->
    case V of
        {Tag, I} when is_integer(I), Tag =/= octet_string ->
            case maps:find(integer_to_binary(I), Map) of
                {ok, S} -> {ok, S, State};
                error ->
                    case T of
                        #{default := D} -> {ok, D, State};
                        _ -> {invalid, unmapped, State}
                    end
            end;
        _ ->
            {invalid, type_mismatch, State}
    end;
convert(#{kind := bit, bit := Bit}, V, _Now, State) ->
    case V of
        {octet_string, B} when is_binary(B) ->
            %% SNMP BITS: bit 0 is the most significant bit of the first octet
            Set = case Bit div 8 < byte_size(B) of
                      true -> (binary:at(B, Bit div 8) bsr (7 - Bit rem 8)) band 1 =:= 1;
                      false -> false
                  end,
            {ok, Set, State};
        {_, I} when is_integer(I) ->
            {ok, (I bsr Bit) band 1 =:= 1, State};
        _ ->
            {invalid, type_mismatch, State}
    end;
convert(#{kind := threshold, op := Op, limit := Limit}, V, _Now, State) ->
    numeric(V, State, fun(X) -> compare(Op, X, Limit) end);
convert(#{kind := counter}, V, _Now, State) ->
    case V of
        {Tag, I} when (Tag =:= counter32 orelse Tag =:= counter64), is_integer(I) -> {ok, I, State};
        _ -> {invalid, type_mismatch, State}
    end;
convert(#{kind := rate, factor := Factor}, V, Now, State) ->
    case {V, State} of
        {{Tag, I}, _} when Tag =/= counter32, Tag =/= counter64; not is_integer(I) ->
            {invalid, type_mismatch, State};
        {{_, I}, undefined} ->
            {skip, {I, Now}};
        {{_, _}, {_, Prev}} when Now =< Prev ->
            {skip, State};
        {{Tag, I}, {PrevV, PrevT}} ->
            Delta = (I - PrevV) band (wrap(Tag) - 1),
            {ok, Delta * 1000 / (Now - PrevT) * Factor, {I, Now}}
    end.

numeric({Tag, I}, State, Fun) when is_integer(I), Tag =/= octet_string ->
    {ok, Fun(I), State};
numeric(_, State, _Fun) ->
    {invalid, type_mismatch, State}.

wrap(counter32) -> 1 bsl 32;
wrap(counter64) -> 1 bsl 64.

compare(gt, X, L) -> X > L;
compare(ge, X, L) -> X >= L;
compare(lt, X, L) -> X < L;
compare(le, X, L) -> X =< L;
compare(eq, X, L) -> X == L;
compare(ne, X, L) -> X /= L.

%%% ===========================================================================
%%% Encode
%%% ===========================================================================

-doc "Engineering value → erl60870 point map fields for `Type` (merge `type` and `ts`).".
-spec encode(atom(), eng()) -> #{value := term(), quality := [overflow], transient => false}.
encode(Type, V) when Type =:= m_sp_na_1; Type =:= m_sp_tb_1 ->
    true = is_boolean(V),
    #{value => V, quality => []};
encode(Type, V) when Type =:= m_dp_na_1; Type =:= m_dp_tb_1 ->
    #{value => dpi(V), quality => []};
encode(m_st_na_1, V) when is_integer(V), V >= -64, V =< 63 ->
    #{value => V, transient => false, quality => []};
encode(Type, X) when Type =:= m_me_na_1; Type =:= m_me_td_1 ->
    %% normalized value: -1 .. +1-2^-15 as a signed 16-bit fraction
    clamp(round(X * 32768), ?INT16_MIN, ?INT16_MAX);
encode(Type, X) when Type =:= m_me_nb_1; Type =:= m_me_te_1 ->
    clamp(round(X), ?INT16_MIN, ?INT16_MAX);
encode(Type, X) when Type =:= m_me_nc_1; Type =:= m_me_tf_1 ->
    clamp(float(X), -?FLOAT32_MAX, ?FLOAT32_MAX);
encode(Type, I) when (Type =:= m_it_na_1 orelse Type =:= m_it_tb_1), is_integer(I), I >= 0 ->
    %% BCR is a signed 32-bit reading: report the counter modulo 2^31
    #{value => I band 16#7FFFFFFF, quality => []}.

dpi(intermediate) -> 0;
dpi(off) -> 1;
dpi(on) -> 2;
dpi(faulty) -> 3.

clamp(V, Min, _Max) when V < Min -> #{value => Min, quality => [overflow]};
clamp(V, _Min, Max) when V > Max -> #{value => Max, quality => [overflow]};
clamp(V, _Min, _Max) -> #{value => V, quality => []}.

%%% ===========================================================================
%%% Deadband
%%% ===========================================================================

-doc """
Whether `New` is sent given the last sent engineering value. `absolute`:
`|New - Last| >= value`; `percent`: relative to `|Last|` (any change from 0).
""".
-spec deadband(map() | undefined, number(), number() | undefined) -> boolean().
deadband(undefined, _New, _Last) -> true;
deadband(_D, _New, undefined) -> true;
deadband(#{kind := absolute, value := Band}, New, Last) ->
    abs(New - Last) >= Band;
deadband(#{kind := percent}, New, Last) when Last == 0 ->
    New /= 0;
deadband(#{kind := percent, value := Pct}, New, Last) ->
    abs(New - Last) >= abs(Last) * Pct / 100.
