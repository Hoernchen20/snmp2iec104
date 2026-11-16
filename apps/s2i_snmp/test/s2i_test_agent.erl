-module(s2i_test_agent).
-moduledoc """
A real OTP `snmpa` agent for common_test (one per node).

Serves SNMPv2-MIB (system group, snmp group, `snmpEngineID`) to
v1/v2c community `public` and to the given USM users, and sends
notifications to the manager address: `notify(trap | inform, Version)`.

USM users are configured under the agent's engine id (polling and traps) and
under the manager's engine id (informs, where the manager is authoritative).
""".

-export([start/2, stop/0, notify/2, engine_id/0, auth_key/3, priv_key/3,
         auth_protocol/1, priv_protocol/1]).

-define(ENGINE, "agentEngine").

-doc """
`Opts`: `port`, `manager => {Ip, Port}`, `manager_engine_id` (string),
`users => [#{name, auth => md5 | sha | ..., auth_password, priv => des | aes,
priv_password}]` (all authPriv).
""".
start(Dir, #{port := Port, manager := Mgr} = Opts) ->
    Conf = filename:join(Dir, "conf") ++ "/",
    Db = filename:join(Dir, "db") ++ "/",
    ok = filelib:ensure_path(Conf),
    ok = filelib:ensure_path(Db),
    Users = maps:get(users, Opts, []),
    MgrEngine = maps:get(manager_engine_id, Opts, "mgrEngine"),
    ok = snmpa_conf:write_agent_config(Conf, "", [
        snmpa_conf:agent_entry(intAgentTransports, [{transportDomainUdpIpv4, {{127, 0, 0, 1}, Port}}]),
        snmpa_conf:agent_entry(snmpEngineID, ?ENGINE),
        snmpa_conf:agent_entry(snmpEngineMaxMessageSize, 1500)]),
    ok = snmpa_conf:write_context_config(Conf, "", [snmpa_conf:context_entry("")]),
    ok = snmpa_conf:write_community_config(Conf, "", [snmpa_conf:community_entry("public")]),
    ok = snmpa_conf:write_standard_config(Conf, "", [
        snmpa_conf:standard_entry(sysDescr, "s2i test agent"),
        snmpa_conf:standard_entry(sysObjectID, [3, 6, 1, 4, 1, 193, 19]),
        snmpa_conf:standard_entry(sysContact, ""),
        snmpa_conf:standard_entry(sysName, "agent"),
        snmpa_conf:standard_entry(sysLocation, ""),
        snmpa_conf:standard_entry(sysServices, 72),
        snmpa_conf:standard_entry(snmpEnableAuthenTraps, disabled)]),
    %% community "public" maps to security name "initial"
    ok = snmpa_conf:write_vacm_config(Conf, "", [
        snmpa_conf:vacm_s2g_entry(v1, "initial", "all"),
        snmpa_conf:vacm_s2g_entry(v2c, "initial", "all"),
        snmpa_conf:vacm_acc_entry("all", "", any, noAuthNoPriv, exact, "internet", "internet", "internet"),
        snmpa_conf:vacm_acc_entry("all", "", usm, authPriv, exact, "internet", "internet", "internet"),
        snmpa_conf:vacm_vtf_entry("internet", [1, 3, 6, 1], included, null)]
        ++ [snmpa_conf:vacm_s2g_entry(usm, N, "all") || #{name := N} <- Users]),
    ok = snmpa_conf:write_usm_config(Conf, "", [usm_entry(E, U) || U <- Users, E <- [?ENGINE, MgrEngine]]),
    V3User = case Users of [#{name := N} | _] -> N; [] -> "none" end,
    ok = snmpa_conf:write_notify_config(Conf, "", [
        snmpa_conf:notify_entry(atom_to_list(T) ++ "_" ++ atom_to_list(V), tag(T, V), T)
        || T <- [trap, inform], V <- [v1, v2c, v3], {T, V} =/= {inform, v1}]),
    ok = snmpa_conf:write_target_addr_config(Conf, "", [
        %% timeout in 1/100 s: informs are retransmitted after 1 s (the
        %% first v3 inform always runs into a time-window report)
        snmpa_conf:target_addr_entry(tag(T, V), transportDomainUdpIpv4, Mgr, 100, 3,
                                     tag(T, V), atom_to_list(V),
                                     case T of inform -> MgrEngine; trap -> "" end, [], 1500)
        || T <- [trap, inform], V <- [v1, v2c, v3], {T, V} =/= {inform, v1}]),
    ok = snmpa_conf:write_target_params_config(Conf, "", [
        snmpa_conf:target_params_entry("v1", v1, v1, "initial", noAuthNoPriv),
        snmpa_conf:target_params_entry("v2c", v2c, v2c, "initial", noAuthNoPriv),
        snmpa_conf:target_params_entry("v3", v3, usm, V3User, authPriv)]),
    _ = application:load(snmp),
    ok = application:set_env(snmp, agent,
                             [{db_dir, Db}, {config, [{dir, Conf}, {force_load, true}]},
                              {mibs, [filename:join(code:priv_dir(snmp), "mibs/SNMPv2-MIB")]},
                              {versions, [v1, v2, v3]}]),
    ok = application:start(snmp).

stop() ->
    _ = application:stop(snmp),
    ok = application:unset_env(snmp, agent).

engine_id() -> ?ENGINE.

-doc "Send `coldStart` as `trap` or `inform` with `Version`; informs report to the caller.".
notify(Type, Version) ->
    snmpa:send_notification(snmp_master_agent, coldStart, {Type, self()},
                            atom_to_list(Type) ++ "_" ++ atom_to_list(Version), []).

tag(T, V) -> atom_to_list(T) ++ "_" ++ atom_to_list(V).

usm_entry(Engine, #{name := N, auth := A, auth_password := AP, priv := P, priv_password := PP}) ->
    snmpa_conf:usm_entry(Engine, N, N, zeroDotZero, auth_protocol(A), "", "",
                         priv_protocol(P), "", "", "", auth_key(A, AP, Engine), priv_key(A, PP, Engine)).

auth_key(Alg, Password, Engine) ->
    snmp:passwd2localized_key(Alg, Password, Engine).

priv_key(Alg, Password, Engine) ->
    lists:sublist(snmp:passwd2localized_key(Alg, Password, Engine), 16).

auth_protocol(md5) -> usmHMACMD5AuthProtocol;
auth_protocol(sha) -> usmHMACSHAAuthProtocol;
auth_protocol(sha224) -> usmHMAC128SHA224AuthProtocol;
auth_protocol(sha256) -> usmHMAC192SHA256AuthProtocol;
auth_protocol(sha384) -> usmHMAC256SHA384AuthProtocol;
auth_protocol(sha512) -> usmHMAC384SHA512AuthProtocol.

priv_protocol(des) -> usmDESPrivProtocol;
priv_protocol(aes) -> usmAesCfb128Protocol.
