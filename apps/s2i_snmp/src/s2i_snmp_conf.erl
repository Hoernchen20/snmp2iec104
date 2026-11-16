-module(s2i_snmp_conf).
-moduledoc """
Canonical `device` entity → snmpm registration data (pure).

The device's secrets must already be opened (plaintext); `s2i_device` does
that with `s2i_secret:open/1` just before registering.

- `user/1`, `target/1`: snmpm user id and target name of a device. Every
  device registers its own snmpm user whose data is the device pid, so
  responses and reports reach the device process directly.
- `agent/3`: `snmpm:register_agent/3` config. snmpm requires an engine id
  for every agent; v1/v2c get a placeholder.
- `usm/2`: `snmpm:register_usm_user/3` arguments, keys localized for the
  agent's engine id (RFC 3414 A.2; privacy key = first 16 octets).
""".

-export([user/1, target/1, agent/3, usm/2, engine_id/1]).

-define(MAX_MESSAGE_SIZE, 65507).
-define(NO_ENGINE, "s2i-no-engine").

-spec user(binary()) -> {s2i_device, binary()}.
user(Name) -> {s2i_device, Name}.

-spec target(binary()) -> string().
target(Name) -> "s2i/" ++ binary_to_list(Name).

-doc "Hex engine id from the configuration → snmpm engine id (octets as a list).".
-spec engine_id(binary()) -> string().
engine_id(Hex) -> binary_to_list(binary:decode_hex(Hex)).

-spec agent(map(), inet:ip4_address(), string() | undefined) -> [{atom(), term()}].
agent(#{port := Port, snmp := Snmp}, Ip, EngineId) ->
    [{taddress, {Ip, Port}},
     {engine_id, case EngineId of undefined -> ?NO_ENGINE; _ -> EngineId end},
     {max_message_size, ?MAX_MESSAGE_SIZE}
     | security(Snmp)].

security(#{version := v1, community := C}) ->
    [{version, v1}, {sec_model, v1}, {community, binary_to_list(C)}];
security(#{version := v2c, community := C}) ->
    [{version, v2}, {sec_model, v2c}, {community, binary_to_list(C)}];
security(#{version := v3, user := U, sec_level := L}) ->
    [{version, v3}, {sec_model, usm}, {sec_name, binary_to_list(U)}, {sec_level, sec_level(L)}].

sec_level(no_auth_no_priv) -> noAuthNoPriv;
sec_level(auth_no_priv) -> authNoPriv;
sec_level(auth_priv) -> authPriv.

-spec usm(map(), string()) -> {string(), string(), [{atom(), term()}]}.
usm(#{version := v3, user := U, sec_level := Level} = Snmp, EngineId) ->
    Name = binary_to_list(U),
    Auth = case Level of
               no_auth_no_priv ->
                   [{auth, usmNoAuthProtocol}];
               _ ->
                   #{auth_protocol := A, auth_password := P} = Snmp,
                   [{auth, auth_protocol(A)}, {auth_key, key(A, P, EngineId)}]
           end,
    Priv = case Level of
               auth_priv ->
                   #{auth_protocol := A2, priv_protocol := PP, priv_password := PPw} = Snmp,
                   [{priv, priv_protocol(PP)}, {priv_key, lists:sublist(key(A2, PPw, EngineId), 16)}];
               _ ->
                   [{priv, usmNoPrivProtocol}]
           end,
    {EngineId, Name, [{sec_name, Name} | Auth ++ Priv]}.

key(Alg, Password, EngineId) ->
    snmp:passwd2localized_key(Alg, binary_to_list(Password), EngineId).

auth_protocol(md5) -> usmHMACMD5AuthProtocol;
auth_protocol(sha) -> usmHMACSHAAuthProtocol;
auth_protocol(sha224) -> usmHMAC128SHA224AuthProtocol;
auth_protocol(sha256) -> usmHMAC192SHA256AuthProtocol;
auth_protocol(sha384) -> usmHMAC256SHA384AuthProtocol;
auth_protocol(sha512) -> usmHMAC384SHA512AuthProtocol.

priv_protocol(des) -> usmDESPrivProtocol;
priv_protocol(aes) -> usmAesCfb128Protocol.
