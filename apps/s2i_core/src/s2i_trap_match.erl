-module(s2i_trap_match).
-moduledoc """
Traps and informs → datapoint values (pure, docs/DESIGN.md §5.4).

- `normalize/1`: snmpm trap info → `#{trap_oid, varbinds}`. SNMPv1 traps get
  their SNMPv2 `snmpTrapOID` (RFC 3584 §3.1): generic 0..5 →
  `snmpTraps.(generic + 1)`, enterprise-specific → `enterprise.0.specific`.
  The SNMPv2 header varbinds (`sysUpTime.0`, `snmpTrapOID.0`) are dropped.
- `compile/1`: canonical profile `trap_rules` → OIDs as integer lists and
  constants as SNMP values (`{integer, N}` / `{octet_string, B}`).
- `match/3`: actions for one trap, in order:
  1. every varbind whose OID is a datapoint OID of the device (varbind match),
  2. every rule whose `trap_oid` and `conditions` match, applied to the
     datapoint of its template, for the instance taken from a varbind
     (`suffix`: last OID component, `value`: the varbind's value).
  An action is `#{oid, value, source}` (+ `auto_reset`, `confirm_get_after`
  of the rule); its value goes through the datapoint's transforms like a
  polled value. Rules that match the trap but find no datapoint (instance
  not configured or not resolved, varbind missing) are returned as misses.
- `poll_applies/3`: the ordering rule. A polled value is applied only if its
  request was sent after the datapoint's last trap.
""".

-export([normalize/1, compile/1, match/3, poll_applies/3]).
-export_type([trap/0, rule/0, action/0]).

-define(SNMP_TRAPS, [1, 3, 6, 1, 6, 3, 1, 1, 5]).
-define(SNMP_TRAP_OID, [1, 3, 6, 1, 6, 3, 1, 1, 4, 1, 0]).
-define(SYS_UPTIME, [1, 3, 6, 1, 2, 1, 1, 3, 0]).

-type oid() :: [non_neg_integer()].
-type value() :: s2i_transform:snmp_value().
-type trap() :: #{trap_oid := oid() | undefined, varbinds := [{oid(), value()}]}.
-type rule() :: #{name := binary(), trap_oid := oid(), conditions := [map()],
                  datapoint := binary(), instance => #{oid := oid(), from := suffix | value},
                  set => value(), take => oid(), auto_reset => #{delay := pos_integer(), value := value()},
                  confirm_get_after => non_neg_integer(), atom() => term()}.
-type action() :: #{oid := oid(), value := value(), source := varbind | binary(),
                    auto_reset => #{delay := pos_integer(), value := value()},
                    confirm_get_after => non_neg_integer()}.
-type lookup() :: #{routes := #{oid() => term()},
                    templates := #{{binary(), non_neg_integer() | device} => oid()},
                    atom() => term()}.

%%% ===========================================================================
%%% Normalisation
%%% ===========================================================================

-spec normalize(tuple()) -> trap().
normalize({Enterprise, Generic, Specific, _Timestamp, Vbs}) when is_integer(Generic) ->
    TrapOid = case Generic of
                  6 -> Enterprise ++ [0, Specific];
                  _ -> ?SNMP_TRAPS ++ [Generic + 1]
              end,
    #{trap_oid => TrapOid, varbinds => varbinds(Vbs)};
normalize({_ErrorStatus, _ErrorIndex, Vbs}) ->
    All = varbinds(Vbs),
    TrapOid = case lists:keyfind(?SNMP_TRAP_OID, 1, All) of
                  {_, {oid, O}} -> O;
                  _ -> undefined
              end,
    #{trap_oid => TrapOid,
      varbinds => [V || {O, _} = V <- All, O =/= ?SNMP_TRAP_OID, O =/= ?SYS_UPTIME]}.

varbinds(Vbs) ->
    [{Oid, s2i_poll:value(Type, Value)} || {varbind, Oid, Type, Value, _} <- Vbs].

%%% ===========================================================================
%%% Rules
%%% ===========================================================================

-spec compile([map()]) -> [rule()].
compile(Rules) ->
    [maps:map(fun compile_field/2, R) || R <- Rules].

compile_field(trap_oid, O) -> oid(O);
compile_field(take, O) -> oid(O);
compile_field(set, V) -> constant(V);
compile_field(conditions, Cs) -> [C#{oid := oid(O), value := constant(V)} || #{oid := O, value := V} = C <- Cs];
compile_field(instance, #{oid := O} = I) -> I#{oid := oid(O)};
compile_field(auto_reset, #{value := V} = A) -> A#{value := constant(V)};
compile_field(_, X) -> X.

oid(B) -> [binary_to_integer(X) || X <- binary:split(B, <<".">>, [global])].

constant(I) when is_integer(I) -> {integer, I};
constant(B) when is_binary(B) -> {octet_string, B}.

-spec match(trap(), [rule()], lookup()) -> {[action()], Misses :: [{binary(), atom()}]}.
match(#{trap_oid := TrapOid, varbinds := Vbs}, Rules, #{routes := Routes, templates := Templates}) ->
    ByVarbind = [#{oid => O, value => V, source => varbind} || {O, V} <- Vbs, is_map_key(O, Routes)],
    {ByRule, Misses} =
        lists:foldr(fun(R, {As, Ms}) ->
                            case rule(R, TrapOid, Vbs, Routes, Templates) of
                                nomatch -> {As, Ms};
                                {ok, A} -> {[A | As], Ms};
                                {miss, Why} -> {As, [{maps:get(name, R), Why} | Ms]}
                            end
                    end, {[], []}, Rules),
    {ByVarbind ++ ByRule, Misses}.

rule(#{trap_oid := TrapOid, conditions := Cs} = R, TrapOid, Vbs, Routes, Templates) ->
    case lists:all(fun(C) -> condition(C, Vbs) end, Cs) of
        false ->
            nomatch;
        true ->
            maybe
                {ok, Key} ?= instance(R, Vbs),
                {ok, Oid} ?= target(maps:get(datapoint, R), Key, Templates, Routes),
                {ok, Value} ?= value(R, Vbs),
                {ok, maps:merge(#{oid => Oid, value => Value, source => maps:get(name, R)},
                                maps:with([auto_reset, confirm_get_after], R))}
            else
                {error, Why} -> {miss, Why}
            end
    end;
rule(_Rule, _TrapOid, _Vbs, _Routes, _Templates) ->
    nomatch.

condition(#{oid := O, op := Op, value := Want}, Vbs) ->
    case first_under(O, Vbs) of
        {ok, _, Got} -> (Op =:= eq) =:= equal(Want, Got);
        error -> false
    end.

equal({integer, N}, {Tag, M}) when is_integer(M), Tag =/= octet_string -> N =:= M;
equal({octet_string, B}, {octet_string, B2}) -> B =:= B2;
equal({octet_string, B}, {oid, L}) when is_list(L) ->
    B =:= iolist_to_binary(lists:join($., [integer_to_binary(I) || I <- L]));
equal(_, _) -> false.

instance(#{instance := #{oid := P, from := suffix}}, Vbs) ->
    N = length(P),
    case [lists:last(O) || {O, _} <- Vbs, lists:prefix(P, O), length(O) =:= N + 1] of
        [Index | _] -> {ok, Index};
        [] -> {error, no_instance}
    end;
instance(#{instance := #{oid := P, from := value}}, Vbs) ->
    case first_under(P, Vbs) of
        {ok, _, {Tag, Index}} when is_integer(Index), Index >= 0, Tag =/= octet_string -> {ok, Index};
        _ -> {error, no_instance}
    end;
instance(_Rule, _Vbs) ->
    {ok, device}.

target(Template, Key, Templates, Routes) ->
    case Templates of
        #{{Template, Key} := Oid} when is_map_key(Oid, Routes) -> {ok, Oid};
        _ -> {error, no_datapoint}
    end.

value(#{set := V}, _Vbs) ->
    {ok, V};
value(#{take := P}, Vbs) ->
    case first_under(P, Vbs) of
        {ok, _, V} -> {ok, V};
        error -> {error, no_value}
    end.

%% The first varbind whose OID is `Prefix` or below it (a table column).
first_under(Prefix, Vbs) ->
    case [{O, V} || {O, V} <- Vbs, lists:prefix(Prefix, O)] of
        [{O, V} | _] -> {ok, O, V};
        [] -> error
    end.

%%% ===========================================================================
%%% Ordering rule
%%% ===========================================================================

-doc "Whether a value polled by a request sent at `SentAt` may overwrite the datapoint.".
-spec poll_applies(oid(), integer(), #{oid() => integer()}) -> boolean().
poll_applies(Oid, SentAt, TrapAt) ->
    case TrapAt of
        #{Oid := T} -> SentAt > T;
        _ -> true
    end.
