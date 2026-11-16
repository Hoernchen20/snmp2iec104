-module(s2i_snmpm).
-moduledoc """
Starts OTP's SNMP manager (`snmpm`) inside the gateway's supervision tree.

`snmpm:start_link/1` returns `ok` instead of `{ok, Pid}`, so the manager's
own supervisor is started directly (see `s2i_snmpm_spike_SUITE`). A minimal
`manager.conf` is generated on every start from the `s2i_snmp` environment:

- `dir` (default `"data/snmp"`): manager config and database,
- `ip` / `port` (default `"0.0.0.0"` / `162`): one UDP socket for requests,
  responses, traps and informs. Port 162 needs `CAP_NET_BIND_SERVICE` or a
  port redirect,
- `engine_id`: hex; when unset, a random engine id is generated once and kept
  in `<dir>/engine_id`. Devices sending SNMPv3 informs need it.

Agents and users are registered at runtime by the devices; the default user
(`s2i_snmpm_user`) receives what arrives from unregistered addresses.
""".

-export([child_spec/0, start_link/0, engine_id/0, local_engine_id/0, manager_conf/3]).

-define(MAX_MESSAGE_SIZE, 65507).

-spec child_spec() -> supervisor:child_spec().
child_spec() ->
    #{id => snmpm, start => {?MODULE, start_link, []}, type => supervisor, shutdown => infinity}.

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    Dir = filename:absname(env(dir, "data/snmp")),
    ok = filelib:ensure_path(Dir),
    {ok, Ip} = inet:parse_ipv4strict_address(env(ip, "0.0.0.0")),
    Port = env(port, 162),
    case check_port(Ip, Port) of
        ok ->
            EngineId = load_engine_id(Dir),
            persistent_term:put({?MODULE, engine_id}, EngineId),
            ok = file:write_file(filename:join(Dir, "manager.conf"), manager_conf(Ip, Port, EngineId)),
            snmpm_supervisor:start_link(normal, [{config, [{dir, Dir ++ "/"}, {db_dir, Dir ++ "/"}]},
                                                 {versions, [v1, v2, v3]},
                                                 {def_user_mod, s2i_snmpm_user},
                                                 {def_user_data, default}]);
        {error, Reason} ->
            %% one clear message instead of snmpm's crash reports
            logger:error("SNMP manager cannot use UDP ~ts:~b: ~ts. Ports below 1024 need "
                         "CAP_NET_BIND_SERVICE (or a port redirect); the port is set by "
                         "s2i_snmp `port` in sys.config.",
                         [inet:ntoa(Ip), Port, inet:format_error(Reason)]),
            {error, {snmp_port, Port, Reason}}
    end.

check_port(Ip, Port) ->
    case gen_udp:open(Port, [{ip, Ip}]) of
        {ok, S} -> gen_udp:close(S);
        {error, _} = E -> E
    end.

-doc """
Content of `manager.conf`, written as Erlang terms with `~w`: snmpm_conf
writes the engine id with `"~s"`, which breaks on octets such as `$"`.
""".
-spec manager_conf(inet:ip4_address(), inet:port_number(), string()) -> iodata().
manager_conf(Ip, Port, EngineId) ->
    [io_lib:format("~w.~n", [E]) || E <- [{transports, [{transportDomainUdpIpv4, {Ip, Port}}]},
                                          {engine_id, EngineId},
                                          {max_message_size, ?MAX_MESSAGE_SIZE}]].

-doc "The gateway's SNMP engine id (hex), e.g. for configuring informs on devices.".
-spec engine_id() -> binary().
engine_id() ->
    binary:encode_hex(list_to_binary(local_engine_id()), lowercase).

-doc "The gateway's SNMP engine id as snmpm uses it (octets as a list).".
-spec local_engine_id() -> string().
local_engine_id() ->
    persistent_term:get({?MODULE, engine_id}).

load_engine_id(Dir) ->
    case env(engine_id, undefined) of
        undefined ->
            File = filename:join(Dir, "engine_id"),
            case file:read_file(File) of
                {ok, Hex} ->
                    binary_to_list(binary:decode_hex(string:trim(Hex)));
                {error, enoent} ->
                    %% RFC 3411: enterprise-less, format 5 (administratively assigned octets)
                    Id = <<16#80, 0, 0, 0, 5, (crypto:strong_rand_bytes(8))/binary>>,
                    ok = file:write_file(File, [binary:encode_hex(Id, lowercase), $\n]),
                    binary_to_list(Id)
            end;
        Hex ->
            binary_to_list(binary:decode_hex(iolist_to_binary(Hex)))
    end.

env(Key, Default) ->
    application:get_env(s2i_snmp, Key, Default).
