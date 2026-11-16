-module(s2i_sample).
-moduledoc """
One SNMP value → IEC writes for all routes of its OID (pure).

Per route (`s2i_routes:route()`), keyed by its IEC address
`{Server, Coa, Ioa}`, the state is `#{t, last, valid}`: the transform state
(`rate`), the last *sent* engineering value and whether the point is
currently published as valid.

- A value is sent only when it changed (any change without a deadband; the
  deadband against the last sent value otherwise), or when the point is not
  valid yet (first value, after invalid input, after `invalidate/2`).
- Unusable input (`s2i_transform` `invalid`, or a value that does not fit the
  IEC type) produces the write `invalid` once; the IEC side keeps the last
  value and sets quality `invalid`.
- Writes are `{Server, {Coa, Ioa}, Spec | invalid}`; `by_server/1` groups
  them for `s2i_iec:publish/2` and `s2i_iec:invalidate/2`.
""".

-export([apply/4, invalidate/2, reset/1, by_server/1]).
-export_type([states/0, write/0]).

-type key() :: {binary(), pos_integer(), non_neg_integer()}.
-type state() :: #{t := s2i_transform:state(), last := term(), valid := boolean()}.
-type states() :: #{key() => state()}.
-type addr() :: {pos_integer(), non_neg_integer()}.
-type write() :: {binary(), addr(), map() | invalid}.
-type ctx() :: #{now := integer(), ts := non_neg_integer()}.

-define(TIME_TAGGED, [m_sp_tb_1, m_dp_tb_1, m_me_td_1, m_me_te_1, m_me_tf_1, m_it_tb_1]).

-spec apply([s2i_routes:route()], s2i_transform:snmp_value(), ctx(), states()) ->
          {[write()], states()}.
apply(Routes, Value, Ctx, States) ->
    {Writes, States1} =
        lists:foldl(fun(R, {Ws, Sts}) ->
                            {W, St} = route(R, Value, Ctx, state(key(R), Sts)),
                            {W ++ Ws, Sts#{key(R) => St}}
                    end, {[], States}, Routes),
    {lists:reverse(Writes), States1}.

route(#{transform := T, type := Type} = R, Value, #{now := Now} = Ctx,
      #{t := TSt, last := Last, valid := Valid} = St) ->
    case s2i_transform:convert(T, Value, Now, TSt) of
        {ok, Eng, TSt1} ->
            case not Valid orelse changed(maps:get(deadband, R, undefined), Eng, Last) of
                false ->
                    {[], St#{t := TSt1}};
                true ->
                    case encode(Type, Eng, Ctx) of
                        {ok, Spec} ->
                            {[{server(R), addr(R), Spec}], #{t => TSt1, last => Eng, valid => true}};
                        error ->
                            invalid(R, St#{t := TSt1})
                    end
            end;
        {skip, TSt1} ->
            {[], St#{t := TSt1}};
        {invalid, _Reason, TSt1} ->
            invalid(R, St#{t := TSt1})
    end.

invalid(R, #{valid := true} = St) -> {[{server(R), addr(R), invalid}], St#{valid := false}};
invalid(_R, St) -> {[], St}.

changed(_Deadband, _New, undefined) -> true;
changed(undefined, New, Last) -> New /= Last;
changed(Deadband, New, Last) when is_number(New), is_number(Last) ->
    s2i_transform:deadband(Deadband, New, Last);
changed(_Deadband, New, Last) -> New /= Last.

encode(Type, Eng, #{ts := Ts}) ->
    try s2i_transform:encode(Type, Eng) of
        Fields ->
            Spec = Fields#{type => Type},
            {ok, case lists:member(Type, ?TIME_TAGGED) of
                     true -> Spec#{ts => Ts};
                     false -> Spec
                 end}
    catch
        error:_ -> error
    end.

-doc "Mark the points of `Routes` invalid (device down, instance lost).".
-spec invalidate([s2i_routes:route()], states()) -> {[write()], states()}.
invalidate(Routes, States) ->
    lists:foldl(fun(R, {Ws, Sts}) ->
                        {W, St} = invalid(R, state(key(R), Sts)),
                        {Ws ++ W, Sts#{key(R) => St}}
                end, {[], States}, Routes).

-doc "Forget all transform states (counter discontinuity, e.g. agent reboot).".
-spec reset(states()) -> states().
reset(States) ->
    maps:map(fun(_, St) -> St#{t := undefined} end, States).

-doc "`#{Server => {[{Addr, Spec}], [InvalidAddr]}}`, order kept.".
-spec by_server([write()]) -> #{binary() => {[{addr(), map()}], [addr()]}}.
by_server(Writes) ->
    Grouped = lists:foldl(
                fun({S, A, invalid}, Acc) ->
                        maps:update_with(S, fun({P, I}) -> {P, [A | I]} end, {[], [A]}, Acc);
                   ({S, A, Spec}, Acc) ->
                        maps:update_with(S, fun({P, I}) -> {[{A, Spec} | P], I} end, {[{A, Spec}], []}, Acc)
                end, #{}, Writes),
    maps:map(fun(_, {P, I}) -> {lists:reverse(P), lists:reverse(I)} end, Grouped).

state(Key, States) ->
    maps:get(Key, States, #{t => undefined, last => undefined, valid => false}).

key(#{server := S, coa := C, ioa := I}) -> {S, C, I}.
addr(#{coa := C, ioa := I}) -> {C, I}.
server(#{server := S}) -> S.
