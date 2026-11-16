-module(s2i_schema).
-moduledoc """
Schema for single configuration entities (`server`, `device`, `profile`).

`normalize/2` validates one entity and returns its **canonical form**:

- map keys are atoms, enumerations are atoms;
- user strings (names, OIDs, hosts, ...) are UTF-8 binaries;
- defaults are filled in, optional absent fields are left out.

The canonical form is JSON-safe (`json:encode/1` round-trips through
`normalize/2`), and `normalize/2` is idempotent on it. Input may use binary
or atom keys and binary or atom enumeration values, so decoded JSON can be
passed in directly; `null` counts as absent. No atoms are created from input.

Errors are collected, not short-circuited: every problem is reported as
`#{path => Path, error => Code}`, where `Path` is a list of field names
(atoms), map keys (binaries) and 0-based list indexes.

Cross-entity checks (references, port conflicts) live in `s2i_validate`.
""".

-export([normalize/2, kinds/0, iec_types/0, mapping_errors/1]).
-export_type([kind/0, path/0, error/0]).

-type kind() :: server | device | profile.
-type path() :: [atom() | binary() | non_neg_integer()].
-type error() :: #{path := path(), error := atom(), detail => map()}.

-define(NAME_RE, "^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$").
-define(DP_NAME_RE, "^[A-Za-z0-9][A-Za-z0-9_./-]{0,127}$").
-define(LABEL_RE, "^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$").

-define(SP, [m_sp_na_1, m_sp_tb_1]).
-define(DP, [m_dp_na_1, m_dp_tb_1]).
-define(ST, [m_st_na_1]).
-define(ME, [m_me_na_1, m_me_nb_1, m_me_nc_1, m_me_td_1, m_me_te_1, m_me_tf_1]).
-define(IT, [m_it_na_1, m_it_tb_1]).
-define(DP_STATES, [off, on, intermediate, faulty]).

%%% ===========================================================================
%%% API
%%% ===========================================================================

-spec kinds() -> [kind()].
kinds() -> [server, device, profile].

-doc "IEC 60870-5-104 monitoring types a mapping may produce (erl60870 v1 set).".
-spec iec_types() -> [atom()].
iec_types() -> ?SP ++ ?DP ++ ?ST ++ ?ME ++ ?IT.

-spec normalize(kind() | term(), term()) -> {ok, map()} | {error, [error()]}.
normalize(Kind, Input) ->
    case spec(Kind) of
        undefined -> {error, [#{path => [], error => unknown_kind}]};
        Spec -> norm(Spec, Input, [])
    end.

-doc "Consistency errors of a canonical mapping (type/transform/deadband).".
-spec mapping_errors(map()) -> [{path(), atom()}].
mapping_errors(Mapping) -> check_mapping(Mapping).

%%% ===========================================================================
%%% Entity specs
%%% ===========================================================================
%%
%% spec() ::
%%     name | dp_name | string | text | secret | password | host | ip | cidr
%%   | oid | oid_template | engine_id | boolean | number | {number, Min}
%%   | {int, Min, Max} | {enum, [atom()]} | {one_of, [spec()]}
%%   | {list, spec(), Opts}          Opts: min, unique, unique_by => [Key]
%%   | {map_of, name | int_key, spec(), Opts}   Opts: min
%%   | {object, [field()], [check()]}
%%   | {union, TagKey, #{Tag => {[field()], [check()]}}}
%% field() :: {Key, spec(), required | optional | defaults | {default, Value}}
%%     `defaults` normalises an empty map, i.e. a sub-object with all defaults.
%% check() :: fun((NormalisedMap) -> [{RelPath, Code}])
%%     runs only when all fields of the object are valid.

spec(server) ->
    {object,
     [{name, name, required},
      {description, text, optional},
      {transport, transport(), required},
      {common_addresses, {list, {int, 1, 65534}, #{min => 1, unique => true}}, required},
      {params, params(), defaults},
      {redundancy, redundancy(), defaults},
      {background_scan, {int, 1000, 86400000}, optional}],
     [fun check_coa_size/1]};
spec(device) ->
    {object,
     [{name, name, required},
      {description, text, optional},
      {enabled, boolean, {default, true}},
      {host, host, required},
      {port, {int, 1, 65535}, {default, 161}},
      {snmp, snmp(), required},
      {timeout, {int, 100, 60000}, {default, 2000}},
      {retries, {int, 0, 10}, {default, 1}},
      {max_varbinds, {int, 1, 1000}, {default, 30}},
      {down_after, {int, 1, 100}, {default, 3}},
      {profile, name, required},
      {ioa_base, {int, 0, 16#FFFFFF}, required},
      {instances, {list, instance(), #{unique_by => [slot, index, key]}}, {default, []}},
      {targets, {map_of, name, {list, target(), #{min => 1, unique => true}}, #{}},
       {default, #{}}},
      {comm_status, comm_status(), optional},
      {overrides, {list, override(), #{}}, {default, []}}],
     []};
spec(profile) ->
    {object,
     [{name, name, required},
      {description, text, optional},
      {ioa_stride, {int, 1, 65535}, {default, 1}},
      {poll_groups, {map_of, name, {int, 1000, 86400000}, #{}}, {default, #{}}},
      {resolvers, {map_of, name, resolver(), #{}}, {default, #{}}},
      {datapoints, {list, datapoint(), #{unique_by => [name]}}, {default, []}},
      {trap_rules, {list, trap_rule(), #{unique_by => [name]}}, {default, []}}],
     [fun check_profile/1]};
spec(_) ->
    undefined.

transport() ->
    Ip = {ip, ip, {default, <<"0.0.0.0">>}},
    {union, kind,
     #{tcp => {[{port, {int, 1, 65535}, {default, 2404}}, Ip], []},
       tls => {[{port, {int, 1, 65535}, {default, 19998}}, Ip,
                {certfile, string, required},
                {keyfile, string, required},
                {cacertfile, string, required},
                {verify, boolean, {default, true}}], []}}}.

params() ->
    {object,
     [{k, {int, 1, 32767}, {default, 12}},
      {w, {int, 1, 32767}, {default, 8}},
      {t1, {int, 1000, 255000}, {default, 15000}},
      {t2, {int, 1000, 255000}, {default, 10000}},
      {t3, {int, 1000, 172800000}, {default, 20000}},
      {coa_size, {int, 1, 2}, {default, 2}},
      {ioa_size, {int, 1, 3}, {default, 3}},
      {cot_size, {int, 1, 2}, {default, 2}}],
     [fun check_params/1]}.

redundancy() ->
    Group = {object,
             [{name, name, required},
              {match, {list, cidr, #{min => 1}}, required},
              {buffer, {int, 1, 1000000}, optional}],
             []},
    {object,
     [{mode, {enum, [connection, single, multiple]}, {default, connection}},
      {buffer, {int, 1, 1000000}, {default, 1000}},
      {groups, {list, Group, #{unique_by => [name]}}, {default, []}}],
     [fun check_redundancy/1]}.

snmp() ->
    Community = {[{community, secret, required}], []},
    {union, version,
     #{v1 => Community,
       v2c => Community,
       v3 => {[{user, string, required},
               {sec_level, {enum, [no_auth_no_priv, auth_no_priv, auth_priv]}, required},
               {auth_protocol, {enum, [md5, sha, sha224, sha256, sha384, sha512]}, optional},
               {auth_password, password, optional},
               {priv_protocol, {enum, [des, aes]}, optional},
               {priv_password, password, optional},
               {engine_id, engine_id, optional}],
              [fun check_v3/1]}}}.

instance() ->
    {object,
     [{slot, {int, 0, 65535}, required},
      {index, {int, 0, 4294967295}, optional},
      {key, {object, [{resolver, name, required}, {value, string, required}], []}, optional}],
     [fun check_instance/1]}.

target() ->
    {object, [{server, name, required}, {coa, {int, 1, 65534}, required}], []}.

%% Per-device changes to the profile's datapoints. References to the
%% profile (datapoint, slots, mapping index) and the consistency of a patched
%% mapping are checked by s2i_expand.
override() ->
    {object,
     [{datapoint, dp_name, required},
      {slots, {list, {int, 0, 65535}, #{min => 1, unique => true}}, optional},
      {enabled, boolean, {default, true}},
      {mappings, {list, mapping_patch(), #{unique_by => [index]}}, {default, []}}],
     []}.

mapping_patch() ->
    {object,
     [{index, {int, 0, 1000}, required},
      {enabled, boolean, {default, true}},
      {type, {enum, iec_types()}, optional},
      {transform, transform(), optional},
      {deadband, deadband(), optional}],
     []}.

comm_status() ->
    {object,
     [{server, name, required},
      {coa, {int, 1, 65534}, required},
      {ioa, {int, 1, 16#FFFFFF}, required},
      {type, {enum, ?SP}, {default, m_sp_tb_1}}],
     []}.

resolver() ->
    {object, [{column, oid, required}], []}.

datapoint() ->
    {object,
     [{name, dp_name, required},
      {description, text, optional},
      {oid, oid_template, required},
      {scope, {enum, [device, instance]}, {default, device}},
      {poll_group, name, optional},
      {mappings, {list, mapping(), #{}}, {default, []}}],
     []}.

%% docs/DESIGN.md §5.4. References to the profile's datapoints are checked
%% in check_profile/1.
trap_rule() ->
    {object,
     [{name, name, required},
      {description, text, optional},
      {trap_oid, oid, required},
      {conditions, {list, trap_condition(), #{}}, {default, []}},
      {datapoint, dp_name, required},
      {instance, {object, [{oid, oid, required},
                           {from, {enum, [suffix, value]}, {default, suffix}}], []}, optional},
      {set, snmp_value(), optional},
      {take, oid, optional},
      {auto_reset, {object, [{delay, {int, 100, 86400000}, required},
                             {value, snmp_value(), required}], []}, optional},
      {confirm_get_after, {int, 0, 3600000}, optional}],
     [fun check_trap_rule/1]}.

trap_condition() ->
    {object,
     [{oid, oid, required},
      {op, {enum, [eq, ne]}, {default, eq}},
      {value, snmp_value(), required}],
     []}.

%% A constant as an SNMP value: integer (any integer syntax) or octet string.
snmp_value() ->
    {one_of, [{int, -(1 bsl 63), (1 bsl 64) - 1}, text]}.

mapping() ->
    {object,
     [{target, name, {default, <<"default">>}},
      {ioa_offset, {int, 0, 16#FFFFFF}, required},
      {type, {enum, iec_types()}, required},
      {transform, transform(), required},
      {deadband, deadband(), optional}],
     [fun check_mapping/1]}.

transform() ->
    State = {one_of, [boolean, {enum, ?DP_STATES}, {int, -(1 bsl 31), 1 bsl 31}]},
    {union, kind,
     #{linear => {[{scale, number, {default, 1}}, {offset, number, {default, 0}}], []},
       enum => {[{map, {map_of, int_key, State, #{min => 1}}, required},
                 {default, State, optional}], []},
       bit => {[{bit, {int, 0, 63}, required}], []},
       threshold => {[{op, {enum, [gt, ge, lt, le, eq, ne]}, required},
                      {limit, number, required}], []},
       counter => {[], []},
       rate => {[{factor, number, {default, 1}}], []}}}.

deadband() ->
    {object, [{kind, {enum, [absolute, percent]}, required},
              {value, {number, 0}, required}], []}.

%%% ===========================================================================
%%% Object-level checks
%%% ===========================================================================

check_coa_size(#{params := #{coa_size := 1}, common_addresses := Coas}) ->
    [{[common_addresses, I], out_of_range} || {I, C} <- enumerate(Coas), C > 254];
check_coa_size(_) ->
    [].

check_params(#{k := K, w := W, t1 := T1, t2 := T2}) ->
    [{[w], w_too_large} || W * 3 > K * 2] ++
    [{[t2], t2_not_below_t1} || T2 >= T1].

check_redundancy(#{mode := multiple, groups := []}) -> [{[groups], required_for_multiple}];
check_redundancy(#{mode := multiple}) -> [];
check_redundancy(#{groups := [_ | _]}) -> [{[groups], only_for_multiple}];
check_redundancy(_) -> [].

check_v3(#{sec_level := Level} = V3) ->
    {Required, Forbidden} =
        case Level of
            no_auth_no_priv -> {[], [auth_protocol, auth_password, priv_protocol, priv_password]};
            auth_no_priv -> {[auth_protocol, auth_password], [priv_protocol, priv_password]};
            auth_priv -> {[auth_protocol, auth_password, priv_protocol, priv_password], []}
        end,
    [{[F], required} || F <- Required, not maps:is_key(F, V3)] ++
    [{[F], not_allowed_for_sec_level} || F <- Forbidden, maps:is_key(F, V3)].

check_instance(#{index := _, key := _}) -> [{[], index_and_key_exclusive}];
check_instance(#{index := _}) -> [];
check_instance(#{key := _}) -> [];
check_instance(_) -> [{[], index_or_key_required}].

check_profile(#{ioa_stride := Stride, poll_groups := Groups, datapoints := Dps} = Profile) ->
    Indexed = enumerate(Dps),
    PerDp = lists:flatmap(
              fun({I, Dp}) ->
                      [{[datapoints, I | P], E} || {P, E} <- check_datapoint(Dp, Stride, Groups)]
              end, Indexed),
    Scopes = maps:from_list([{N, S} || #{name := N, scope := S} <- Dps]),
    PerRule = [{[trap_rules, I | P], E}
               || {I, R} <- enumerate(maps:get(trap_rules, Profile, [])),
                  {P, E} <- check_rule_datapoint(R, Scopes)],
    PerDp ++ duplicate_offsets(Indexed) ++ PerRule.

check_trap_rule(R) ->
    case {maps:is_key(set, R), maps:is_key(take, R)} of
        {true, true} -> [{[take], set_and_take_exclusive}];
        {false, false} -> [{[set], set_or_take_required}];
        _ -> []
    end.

check_rule_datapoint(#{datapoint := D} = R, Scopes) ->
    case {maps:find(D, Scopes), maps:is_key(instance, R)} of
        {error, _} -> [{[datapoint], unknown_datapoint}];
        {{ok, instance}, false} -> [{[instance], required_for_instance_scope}];
        {{ok, device}, true} -> [{[instance], not_allowed_for_device_scope}];
        _ -> []
    end.

check_datapoint(#{name := Name, oid := Oid, scope := Scope} = Dp, Stride, Groups) ->
    HasIndex = has_index_placeholder(Oid),
    HasSlot = binary:match(Name, <<"{slot}">>) =/= nomatch,
    Placeholders =
        case Scope of
            instance ->
                [{[oid], index_placeholder_required} || not HasIndex] ++
                [{[name], slot_placeholder_required} || not HasSlot];
            device ->
                [{[oid], index_placeholder_not_allowed} || HasIndex] ++
                [{[name], slot_placeholder_not_allowed} || HasSlot]
        end,
    PollGroup =
        case Dp of
            #{poll_group := G} when not is_map_key(G, Groups) -> [{[poll_group], unknown_poll_group}];
            _ -> []
        end,
    Stride1 =
        [{[mappings, J, ioa_offset], offset_exceeds_stride}
         || Scope =:= instance,
            {J, #{ioa_offset := Off}} <- enumerate(maps:get(mappings, Dp)),
            Off >= Stride],
    Placeholders ++ PollGroup ++ Stride1.

%% Two mappings of the same scope and target label must not share an offset.
duplicate_offsets(IndexedDps) ->
    Addrs = [{{Scope, T, Off}, [datapoints, I, mappings, J, ioa_offset]}
             || {I, #{scope := Scope, mappings := Ms}} <- IndexedDps,
                {J, #{target := T, ioa_offset := Off}} <- enumerate(Ms)],
    {_, Errors} = lists:foldl(
                    fun({Key, Path}, {Seen, Acc}) ->
                            case sets:is_element(Key, Seen) of
                                true -> {Seen, [{Path, duplicate} | Acc]};
                                false -> {sets:add_element(Key, Seen), Acc}
                            end
                    end, {sets:new([{version, 2}]), []}, Addrs),
    lists:reverse(Errors).

check_mapping(#{type := Type, transform := #{kind := Kind} = Tr} = M) ->
    case lists:member(Type, compatible_types(Kind)) of
        false ->
            [{[type], incompatible_transform}];
        true ->
            enum_states(Type, Tr) ++
            [{[deadband], not_applicable}
             || maps:is_key(deadband, M), not lists:member(Type, ?ME)]
    end.

compatible_types(linear) -> ?ME;
compatible_types(enum) -> ?SP ++ ?DP ++ ?ST;
compatible_types(bit) -> ?SP;
compatible_types(threshold) -> ?SP;
compatible_types(counter) -> ?IT;
compatible_types(rate) -> ?ME.

enum_states(Type, #{kind := enum, map := Map} = Tr) ->
    [{[transform, map, K], invalid_state}
     || K := V <- maps:iterator(Map, ordered), not valid_state(Type, V)] ++
    [{[transform, default], invalid_state}
     || is_map_key(default, Tr), not valid_state(Type, maps:get(default, Tr))];
enum_states(_, _) ->
    [].

valid_state(Type, V) ->
    case lists:member(Type, ?SP) of
        true -> is_boolean(V);
        false ->
            case lists:member(Type, ?DP) of
                true -> lists:member(V, ?DP_STATES);
                false -> is_integer(V) andalso V >= -64 andalso V =< 63
            end
    end.

%%% ===========================================================================
%%% Spec interpreter
%%% ===========================================================================

norm({object, Fields, Checks}, V, P) when is_map(V) ->
    norm_object(Fields, Checks, V, P);
norm({union, Tag, Variants}, V, P) when is_map(V) ->
    Tags = lists:sort(maps:keys(Variants)),
    case lookup(Tag, V) of
        absent ->
            err(P, [Tag], required);
        {ok, T} ->
            case to_enum(T, Tags) of
                {ok, A} ->
                    {Fields, Checks} = maps:get(A, Variants),
                    norm_object([{Tag, {enum, Tags}, required} | Fields], Checks, V, P);
                error ->
                    err(P, [Tag], invalid_value)
            end
    end;
norm({object, _, _}, _, P) -> err(P, invalid_type);
norm({union, _, _}, _, P) -> err(P, invalid_type);

norm({list, Spec, Opts}, V, P) when is_list(V) ->
    Results = [norm(Spec, E, [I | P]) || {I, E} <- enumerate(V)],
    case collect(Results) of
        {ok, Items} ->
            Min = maps:get(min, Opts, 0),
            case length(Items) < Min of
                true -> err(P, too_short);
                false -> list_unique(Items, Opts, P)
            end;
        Error ->
            Error
    end;
norm({list, _, _}, _, P) -> err(P, invalid_type);

norm({map_of, KeySpec, Spec, Opts}, V, P) when is_map(V) ->
    Results = [norm_entry(KeySpec, Spec, K, E, P)
               || K := E <- maps:iterator(V, ordered)],
    case collect(Results) of
        {ok, Pairs} ->
            map_unique(Pairs, maps:get(min, Opts, 0), P);
        Error ->
            Error
    end;
norm({map_of, _, _, _}, _, P) -> err(P, invalid_type);

norm({one_of, Specs}, V, P) ->
    case [N || S <- Specs, {ok, N} <- [norm(S, V, P)]] of
        [N | _] -> {ok, N};
        [] -> err(P, invalid_value)
    end;

norm({enum, Allowed}, V, P) ->
    case to_enum(V, Allowed) of
        {ok, A} -> {ok, A};
        error -> err(P, invalid_value)
    end;
norm({int, Min, Max}, V, P) when is_integer(V) ->
    in_range(V, Min, Max, P);
norm({int, _, _}, _, P) -> err(P, invalid_type);
norm(number, V, _P) when is_number(V) -> {ok, V};
norm({number, Min}, V, P) when is_number(V) ->
    case V >= Min of true -> {ok, V}; false -> err(P, out_of_range) end;
norm(number, _, P) -> err(P, invalid_type);
norm({number, _}, _, P) -> err(P, invalid_type);
norm(boolean, V, _P) when is_boolean(V) -> {ok, V};
norm(boolean, _, P) -> err(P, invalid_type);

norm(name, V, P) ->
    with_binary(V, P, invalid_name,
                fun(B) -> matches(B, ?NAME_RE) end, invalid_name);
norm(dp_name, V, P) ->
    with_binary(V, P, invalid_name,
                fun(B) ->
                        Plain = binary:replace(B, <<"{slot}">>, <<"0">>, [global]),
                        matches(Plain, ?DP_NAME_RE)
                end, invalid_name);
norm(string, V, P) -> text(V, 1, 255, P);
norm(text, V, P) -> text(V, 0, 1000, P);
%% Secrets are plaintext (sealed by s2i_config on write) or s2i_secret
%% envelopes, which are opaque here: only plaintext has length rules.
norm(Secret, V, P) when Secret =:= secret; Secret =:= password ->
    case s2i_secret:is_sealed(V) of
        true ->
            case s2i_secret:parse(V) of
                {ok, _, _} -> {ok, V};
                error -> err(P, invalid_format)
            end;
        false when Secret =:= secret ->
            text(V, 1, 255, P);
        false ->
            case text(V, 1, 255, P) of
                {ok, B} when byte_size(B) < 8 -> err(P, too_short);
                Other -> Other
            end
    end;

norm(ip, V, P) ->
    convert(V, P, fun parse_ip/1);
norm(host, V, P) ->
    convert(V, P, fun(B) ->
                          case parse_ip(B) of
                              {ok, Ip} -> {ok, Ip};
                              error -> parse_hostname(B)
                          end
                  end);
norm(cidr, V, P) ->
    convert(V, P, fun parse_cidr/1);
norm(oid, V, P) ->
    convert(V, P, fun parse_oid/1);
norm(oid_template, V, P) ->
    convert(V, P, fun parse_oid_template/1);
norm(engine_id, V, P) ->
    convert(V, P, fun parse_engine_id/1).

norm_object(Fields, Checks, V, P) ->
    Known = [atom_to_binary(K) || {K, _, _} <- Fields],
    Unknown = [#{path => lists:reverse([K | P]), error => unknown_field}
               || K <- lists:sort(maps:keys(V)), not lists:member(key_bin(K), Known)],
    Results = [norm_field(F, V, P) || F <- Fields],
    case {Unknown, collect(Results)} of
        {[], {ok, Pairs}} ->
            Obj = maps:from_list(lists:append(Pairs)),
            case lists:append([C(Obj) || C <- Checks]) of
                [] -> {ok, Obj};
                Errs -> {error, [#{path => lists:reverse(P) ++ Rel, error => E}
                                 || {Rel, E} <- Errs]}
            end;
        {Unknown, {ok, _}} ->
            {error, Unknown};
        {Unknown, {error, Errs}} ->
            {error, Unknown ++ Errs}
    end.

norm_field({Key, Spec, Presence}, V, P) ->
    case {lookup(Key, V), Presence} of
        {{ok, Val}, _} ->
            case norm(Spec, Val, [Key | P]) of
                {ok, N} -> {ok, [{Key, N}]};
                Error -> Error
            end;
        {absent, required} -> err(P, [Key], required);
        {absent, optional} -> {ok, []};
        {absent, {default, D}} -> {ok, [{Key, D}]};
        {absent, defaults} ->
            case norm(Spec, #{}, [Key | P]) of
                {ok, N} -> {ok, [{Key, N}]};
                Error -> Error
            end
    end.

norm_entry(KeySpec, Spec, K, E, P) ->
    case norm_key(KeySpec, K) of
        {ok, NK} ->
            case norm(Spec, E, [NK | P]) of
                {ok, N} -> {ok, {NK, N}};
                Error -> Error
            end;
        {error, Code} ->
            err([key_bin(K) | P], Code)
    end.

norm_key(name, K) when is_atom(K); is_binary(K) ->
    B = key_bin(K),
    case matches(B, ?NAME_RE) of
        true -> {ok, B};
        false -> {error, invalid_name}
    end;
norm_key(int_key, K) when is_integer(K) ->
    {ok, integer_to_binary(K)};
norm_key(int_key, K) when is_binary(K) ->
    try binary_to_integer(K) of
        I -> {ok, integer_to_binary(I)}
    catch
        error:badarg -> {error, invalid_format}
    end;
norm_key(name, _) -> {error, invalid_name};
norm_key(int_key, _) -> {error, invalid_format}.

list_unique(Items, Opts, P) ->
    Whole = case maps:get(unique, Opts, false) of
                true -> dups([{I, X} || {I, X} <- enumerate(Items)], []);
                false -> []
            end,
    ByKey = [{[I, K], duplicate}
             || K <- maps:get(unique_by, Opts, []),
                {I, _} <- dups([{I, maps:get(K, X)}
                                || {I, X} <- enumerate(Items), is_map_key(K, X)], [])],
    case [{[I], duplicate} || {I, _} <- Whole] ++ ByKey of
        [] -> {ok, Items};
        Errs -> {error, [#{path => lists:reverse(P) ++ Rel, error => E}
                         || {Rel, E} <- lists:sort(Errs)]}
    end.

map_unique(Pairs, Min, P) ->
    case [{K, duplicate} || {_, K} <- dups(enumerate([K || {K, _} <- Pairs]), [])] of
        [] when length(Pairs) < Min -> err(P, too_short);
        [] -> {ok, maps:from_list(Pairs)};
        Errs -> {error, [#{path => lists:reverse([K | P]), error => E} || {K, E} <- Errs]}
    end.

%% Later occurrences of an already-seen value, as {Index, Value}.
dups([], _Seen) -> [];
dups([{I, X} | Rest], Seen) ->
    case lists:member(X, Seen) of
        true -> [{I, X} | dups(Rest, Seen)];
        false -> dups(Rest, [X | Seen])
    end.

collect(Results) ->
    {Oks, Errs} = lists:foldr(fun collect1/2, {[], []}, Results),
    case Errs of
        [] -> {ok, Oks};
        _ -> {error, Errs}
    end.

collect1({ok, V}, {Oks, Errs}) -> {[V | Oks], Errs};
collect1({error, E}, {Oks, Errs}) -> {Oks, E ++ Errs}.

%%% ===========================================================================
%%% Scalars
%%% ===========================================================================

with_binary(V, P, TypeErr, Valid, InvalidErr) ->
    case to_binary(V) of
        {ok, B} ->
            case Valid(B) of
                true -> {ok, B};
                false -> err(P, InvalidErr)
            end;
        error ->
            err(P, TypeErr)
    end.

text(V, Min, Max, P) ->
    case to_binary(V) of
        {ok, B} ->
            Len = string:length(B),
            if Len < Min -> err(P, required);
               Len > Max -> err(P, too_long);
               true -> {ok, B}
            end;
        error ->
            err(P, invalid_type)
    end.

convert(V, P, Parse) ->
    case to_binary(V) of
        {ok, B} ->
            case Parse(B) of
                {ok, N} -> {ok, N};
                error -> err(P, invalid_format)
            end;
        error ->
            err(P, invalid_type)
    end.

parse_ip(B) ->
    case inet:parse_strict_address(binary_to_list(B)) of
        {ok, Addr} -> {ok, list_to_binary(inet:ntoa(Addr))};
        {error, _} -> error
    end.

parse_hostname(B) ->
    Labels = binary:split(B, <<".">>, [global]),
    AllNumeric = matches(B, "^[0-9.]+$"),
    case byte_size(B) =< 253 andalso not AllNumeric
         andalso lists:all(fun(L) -> matches(L, ?LABEL_RE) end, Labels) of
        true -> {ok, string:lowercase(B)};
        false -> error
    end.

parse_cidr(B) ->
    case binary:split(B, <<"/">>) of
        [A, Len] ->
            case {inet:parse_strict_address(binary_to_list(A)), (catch binary_to_integer(Len))} of
                {{ok, Addr}, N} when is_integer(N), N >= 0,
                                     (tuple_size(Addr) =:= 4 andalso N =< 32) orelse
                                     (tuple_size(Addr) =:= 8 andalso N =< 128) ->
                    {ok, iolist_to_binary([inet:ntoa(Addr), $/, integer_to_binary(N)])};
                _ ->
                    error
            end;
        _ ->
            error
    end.

parse_oid(<<".", B/binary>>) ->
    parse_oid(B);
parse_oid(B) ->
    Parts = binary:split(B, <<".">>, [global]),
    case length(Parts) >= 2 andalso lists:all(fun(X) -> matches(X, "^[0-9]+$") end, Parts) of
        true ->
            [First | _] = Ints = [binary_to_integer(X) || X <- Parts],
            case First =< 2 of
                true -> {ok, join_oid(Ints)};
                false -> error
            end;
        false ->
            error
    end.

parse_oid_template(B) ->
    case has_index_placeholder(B) of
        true ->
            Prefix = binary:part(B, 0, byte_size(B) - byte_size(<<".{index}">>)),
            case parse_oid(Prefix) of
                {ok, O} -> {ok, <<O/binary, ".{index}">>};
                error -> error
            end;
        false ->
            parse_oid(B)
    end.

has_index_placeholder(B) ->
    Suffix = <<".{index}">>,
    byte_size(B) > byte_size(Suffix) andalso
        binary:part(B, byte_size(B), -byte_size(Suffix)) =:= Suffix.

join_oid(Ints) ->
    iolist_to_binary(lists:join($., [integer_to_binary(I) || I <- Ints])).

%% RFC 3411 snmpEngineID: 5..32 octets, written as hex (colons allowed).
parse_engine_id(B) ->
    Hex = string:lowercase(binary:replace(B, <<":">>, <<>>, [global])),
    Bytes = byte_size(Hex) div 2,
    case byte_size(Hex) rem 2 =:= 0 andalso Bytes >= 5 andalso Bytes =< 32
         andalso matches(Hex, "^[0-9a-f]+$") of
        true -> {ok, Hex};
        false -> error
    end.

%%% ===========================================================================
%%% Helpers
%%% ===========================================================================

lookup(Key, Map) ->
    case maps:find(Key, Map) of
        {ok, null} -> absent;
        {ok, V} -> {ok, V};
        error ->
            case maps:find(atom_to_binary(Key), Map) of
                {ok, null} -> absent;
                {ok, V} -> {ok, V};
                error -> absent
            end
    end.

to_enum(V, Allowed) when is_atom(V) ->
    case lists:member(V, Allowed) of
        true -> {ok, V};
        false -> error
    end;
to_enum(V, Allowed) when is_binary(V) ->
    case [A || A <- Allowed, atom_to_binary(A) =:= V] of
        [A] -> {ok, A};
        [] -> error
    end;
to_enum(_, _) ->
    error.

to_binary(B) when is_binary(B) ->
    case unicode:characters_to_binary(B) of
        B -> {ok, B};
        _ -> error
    end;
to_binary(L) when is_list(L) ->
    case io_lib:printable_unicode_list(L) of
        true -> {ok, unicode:characters_to_binary(L)};
        false -> error
    end;
to_binary(_) ->
    error.

key_bin(K) when is_atom(K) -> atom_to_binary(K);
key_bin(K) when is_binary(K) -> K;
key_bin(K) -> iolist_to_binary(io_lib:format("~p", [K])).

matches(B, Re) ->
    re:run(B, Re, [unicode, {capture, none}]) =:= match.

in_range(V, Min, Max, P) ->
    case V >= Min andalso V =< Max of
        true -> {ok, V};
        false -> err(P, out_of_range)
    end.

enumerate(List) ->
    lists:zip(lists:seq(0, length(List) - 1), List).

err(RevPath, Code) ->
    {error, [#{path => lists:reverse(RevPath), error => Code}]}.

err(RevPath, Suffix, Code) ->
    {error, [#{path => lists:reverse(RevPath) ++ Suffix, error => Code}]}.
