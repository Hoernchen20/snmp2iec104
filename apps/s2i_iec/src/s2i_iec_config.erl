-module(s2i_iec_config).
-moduledoc """
Canonical `server` entity → erl60870 `iec60870:start_server/2` config (pure).

Fields that do not concern the library (`name`, `description`,
`background_scan`) are left out, so the result can be compared to decide
whether a running server must be restarted.
""".

-export([server/1, seed/1, name/1, ref/1, restarts/2]).

-doc "Registry name of the erl60870 server for a configured server.".
-spec name(binary()) -> {s2i, binary()}.
name(Server) -> {s2i, Server}.

-doc "Server reference for the `iec60870_server` API.".
-spec ref(binary()) -> {via, iec60870_registry, {s2i, binary()}}.
ref(Server) -> {via, iec60870_registry, name(Server)}.

-doc """
Servers that activating `New` (`#{Name => Entity}`) over `Old` would restart,
dropping their connections: present in both with a different
`server/1` translation (§7; `description`, `background_scan` do not count).
""".
-spec restarts(#{binary() => map()}, #{binary() => map()}) -> [binary()].
restarts(Old, New) ->
    [N || N := E <- maps:iterator(New, ordered), #{N := O} <- [Old], server(O) =/= server(E)].

-spec server(map()) -> map().
server(#{name := Name, transport := Transport, common_addresses := Coas,
         params := Params, redundancy := Redundancy}) ->
    #{transport => transport(Transport),
      common_addresses => Coas,
      params => Params,
      redundancy => redundancy(Redundancy),
      data_model => {s2i_iec_dm, #{server => Name}},
      callback => {s2i_iec_callback, #{server => Name}}}.

transport(#{kind := tcp, ip := Ip, port := Port}) ->
    {tcp, [{ip, ip(Ip)}, {port, Port}]};
transport(#{kind := tls, ip := Ip, port := Port, certfile := Cert, keyfile := Key,
            cacertfile := Ca, verify := Verify}) ->
    {tls, [{ip, ip(Ip)}, {port, Port},
           {certfile, binary_to_list(Cert)},
           {keyfile, binary_to_list(Key)},
           {cacertfile, binary_to_list(Ca)}]
          ++ [{verify, verify_none} || not Verify]}.

redundancy(#{mode := multiple, buffer := Buffer, groups := Groups}) ->
    #{mode => multiple, buffer => Buffer, groups => [group(G) || G <- Groups]};
redundancy(#{mode := Mode, buffer := Buffer}) ->
    #{mode => Mode, buffer => Buffer}.

group(#{name := Name, match := Cidrs} = G) ->
    Out = #{name => Name, match => [cidr(C) || C <- Cidrs]},
    case G of
        #{buffer := B} -> Out#{buffer => B};
        _ -> Out
    end.

cidr(Cidr) ->
    [Addr, Len] = binary:split(Cidr, <<"/">>),
    {ip, ip(Addr), binary_to_integer(Len)}.

ip(Bin) ->
    {ok, Ip} = inet:parse_strict_address(binary_to_list(Bin)),
    Ip.

-doc "Value of a point before its first good value: quality `invalid`.".
-spec seed(atom()) -> map().
seed(Type) ->
    #{type => Type, value => seed_value(Type), quality => [invalid]}.

seed_value(T) when T =:= m_sp_na_1; T =:= m_sp_tb_1 -> false;
seed_value(T) when T =:= m_me_nc_1; T =:= m_me_tf_1 -> 0.0;
seed_value(_) -> 0.
