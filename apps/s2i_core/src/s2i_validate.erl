-module(s2i_validate).
-moduledoc """
Validation of a whole configuration:

```erlang
#{servers  => #{Name => Server},
  profiles => #{Name => Profile},
  devices  => #{Name => Device}}
```

- `entities/1` normalises every entity (`s2i_schema`) and checks that each map
  key equals the entity's `name`. Dangling references are allowed; this is
  what the staged configuration must satisfy.
- `config/1` additionally checks references between entities, listener
  port conflicts and, if those pass, the expansion (`s2i_expand:config/1`:
  overrides, IOA collisions and ranges); this is what an activated
  configuration must satisfy.

Errors use the `s2i_schema` format, with paths prefixed by section and name,
e.g. `[devices, <<"sw-a">>, targets, <<"default">>, 0, coa]`. If any entity
fails its schema, only schema errors are returned (reference checks on broken
entities would just add noise).

""".

-export([config/1, entities/1, empty/0, sections/0]).

-type config() :: #{servers := #{binary() => map()},
                    profiles := #{binary() => map()},
                    devices := #{binary() => map()}}.
-export_type([config/0]).

-define(SECTIONS, [{servers, server}, {profiles, profile}, {devices, device}]).

-spec empty() -> config().
empty() -> #{servers => #{}, profiles => #{}, devices => #{}}.

-doc "Section name and the entity kind stored in it.".
-spec sections() -> [{atom(), s2i_schema:kind()}].
sections() -> ?SECTIONS.

-spec config(term()) -> {ok, config()} | {error, [s2i_schema:error()]}.
config(Input) ->
    case entities(Input) of
        {ok, Config} ->
            case references(Config) ++ port_conflicts(Config) of
                [] ->
                    case s2i_expand:config(Config) of
                        {ok, _} -> {ok, Config};
                        Error -> Error
                    end;
                Errors ->
                    {error, [#{path => P, error => E} || {P, E} <- Errors]}
            end;
        Error ->
            Error
    end.

-spec entities(term()) -> {ok, config()} | {error, [s2i_schema:error()]}.
entities(Input) when is_map(Input) ->
    Known = [atom_to_binary(S) || {S, _} <- ?SECTIONS],
    Unknown = [#{path => [K], error => unknown_field}
               || K <- maps:keys(Input), not lists:member(bin(K), Known)],
    {Sections, Errors} =
        lists:foldr(
          fun({Section, Kind}, {Acc, Errs}) ->
                  {S, E} = section(Section, Kind, get(Section, Input)),
                  {Acc#{Section => S}, E ++ Errs}
          end, {#{}, []}, ?SECTIONS),
    case Unknown ++ Errors of
        [] -> {ok, Sections};
        All -> {error, All}
    end;
entities(_) ->
    {error, [#{path => [], error => invalid_type}]}.

%%% ---------------------------------------------------------------------------

section(_Section, _Kind, absent) ->
    {#{}, []};
section(Section, Kind, Entities) when is_map(Entities) ->
    maps:fold(
      fun(Key, Entity, {Acc, Errs}) ->
              Name = bin(Key),
              Prefix = [Section, Name],
              case s2i_schema:normalize(Kind, Entity) of
                  {ok, #{name := Name} = N} ->
                      {Acc#{Name => N}, Errs};
                  {ok, _} ->
                      {Acc, [#{path => Prefix ++ [name], error => name_mismatch} | Errs]};
                  {error, Es} ->
                      {Acc, [E#{path := Prefix ++ P} || #{path := P} = E <- Es] ++ Errs}
              end
      end, {#{}, []}, Entities);
section(Section, _Kind, _) ->
    {#{}, [#{path => [Section], error => invalid_type}]}.

get(Section, Input) ->
    case maps:find(Section, Input) of
        {ok, V} -> V;
        error -> maps:get(atom_to_binary(Section), Input, absent)
    end.

%%% ---------------------------------------------------------------------------
%%% Reference checks
%%% ---------------------------------------------------------------------------

references(#{devices := Devices, profiles := Profiles, servers := Servers}) ->
    lists:append([device_refs(N, D, Profiles, Servers)
                  || N := D <- maps:iterator(Devices, ordered)]).

device_refs(Name, Device = #{profile := ProfileName}, Profiles, Servers) ->
    P = [devices, Name],
    case maps:find(ProfileName, Profiles) of
        error ->
            [{P ++ [profile], unknown_profile}];
        {ok, Profile} ->
            target_refs(P, Device, Profile, Servers) ++
            instance_refs(P, Device, Profile) ++
            comm_status_refs(P, Device, Servers)
    end.

target_refs(P, #{targets := Targets}, Profile, Servers) ->
    Labels = profile_labels(Profile),
    lists:append(
      [case lists:member(Label, Labels) of
           false ->
               [{P ++ [targets, Label], unknown_target_label}];
           true ->
               lists:append([server_coa_refs(P ++ [targets, Label, I], T, Servers)
                             || {I, T} <- enumerate(Bindings)])
       end
       || Label := Bindings <- maps:iterator(Targets, ordered)]).

instance_refs(P, #{instances := Instances}, #{resolvers := Resolvers}) ->
    [{P ++ [instances, I, key, resolver], unknown_resolver}
     || {I, #{key := #{resolver := R}}} <- enumerate(Instances),
        not is_map_key(R, Resolvers)].

comm_status_refs(P, #{comm_status := #{ioa := Ioa} = Cs}, Servers) ->
    Path = P ++ [comm_status],
    case server_coa_refs(Path, Cs, Servers) of
        [] ->
            #{params := #{ioa_size := Size}} = maps:get(maps:get(server, Cs), Servers),
            [{Path ++ [ioa], out_of_range} || Ioa > max_ioa(Size)];
        Errors ->
            Errors
    end;
comm_status_refs(_P, _Device, _Servers) ->
    [].

server_coa_refs(Path, #{server := S, coa := Coa}, Servers) ->
    case maps:find(S, Servers) of
        error -> [{Path ++ [server], unknown_server}];
        {ok, #{common_addresses := Coas}} ->
            [{Path ++ [coa], unknown_coa} || not lists:member(Coa, Coas)]
    end.

profile_labels(#{datapoints := Dps}) ->
    lists:usort([T || #{mappings := Ms} <- Dps, #{target := T} <- Ms]).

max_ioa(Size) -> (1 bsl (8 * Size)) - 1.

%%% ---------------------------------------------------------------------------
%%% Listener port conflicts (the later server, by name, is reported)
%%% ---------------------------------------------------------------------------

port_conflicts(#{servers := Servers}) ->
    Listeners = [{N, Ip, Port}
                 || N := #{transport := #{ip := Ip, port := Port}}
                        <- maps:iterator(Servers, ordered)],
    conflicts(Listeners, []).

conflicts([], _Earlier) ->
    [];
conflicts([{N, Ip, Port} = L | Rest], Earlier) ->
    Clash = [x || {_, Ip2, Port2} <- Earlier, Port2 =:= Port,
                  Ip2 =:= Ip orelse wildcard(Ip) orelse wildcard(Ip2)],
    [{[servers, N, transport, port], port_conflict} || Clash =/= []] ++
        conflicts(Rest, [L | Earlier]).

wildcard(<<"0.0.0.0">>) -> true;
wildcard(<<"::">>) -> true;
wildcard(_) -> false.

%%% ---------------------------------------------------------------------------

bin(K) when is_binary(K) -> K;
bin(K) when is_atom(K) -> atom_to_binary(K);
bin(K) when is_list(K) -> unicode:characters_to_binary(K);
bin(K) -> iolist_to_binary(io_lib:format("~p", [K])).

enumerate(List) ->
    lists:zip(lists:seq(0, length(List) - 1), List).
