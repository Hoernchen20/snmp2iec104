-module(s2i_snmp_discover).
-moduledoc """
SNMPv3 engine id discovery (RFC 3414 §4), which snmpm does not offer.

An unauthenticated, reportable GET with an empty engine id and user name is
sent from a separate UDP socket; the agent answers with a
`usmStatsUnknownEngineIDs` report whose header carries its
`msgAuthoritativeEngineID`.
""".

%% the records of the OTP header are untyped
-compile(nowarn_untyped_record).
-define(SNMP_USE_V3, true).
-include_lib("snmp/include/snmp_types.hrl").

-export([engine_id/4, probe/2, parse/2]).

-spec engine_id(inet:ip4_address(), inet:port_number(), pos_integer(), non_neg_integer()) ->
          {ok, string()} | {error, term()}.
engine_id(Ip, Port, Timeout, Retries) ->
    case gen_udp:open(0, [binary, {active, false}]) of
        {ok, Sock} ->
            try attempt(Sock, Ip, Port, Timeout, Retries)
            after gen_udp:close(Sock)
            end;
        {error, _} = E ->
            E
    end.

attempt(Sock, Ip, Port, Timeout, Left) ->
    MsgId = rand:uniform(16#7FFFFFFF),
    ok = gen_udp:send(Sock, Ip, Port, probe(MsgId, rand:uniform(16#7FFFFFFF))),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    case await(Sock, Ip, Port, MsgId, Deadline) of
        {ok, _} = Ok -> Ok;
        timeout when Left > 0 -> attempt(Sock, Ip, Port, Timeout, Left - 1);
        timeout -> {error, timeout}
    end.

await(Sock, Ip, Port, MsgId, Deadline) ->
    case gen_udp:recv(Sock, 0, max(0, Deadline - erlang:monotonic_time(millisecond))) of
        {ok, {Ip, Port, Packet}} ->
            case parse(Packet, MsgId) of
                {ok, _} = Ok -> Ok;
                error -> await(Sock, Ip, Port, MsgId, Deadline)
            end;
        {ok, _FromElsewhere} ->
            await(Sock, Ip, Port, MsgId, Deadline);
        {error, _} ->
            timeout
    end.

-doc "Encoded discovery request.".
-spec probe(pos_integer(), pos_integer()) -> binary().
probe(MsgId, ReqId) ->
    Sec = snmp_pdus:enc_usm_security_parameters(
            #usmSecurityParameters{msgAuthoritativeEngineID = "",
                                   msgAuthoritativeEngineBoots = 0,
                                   msgAuthoritativeEngineTime = 0,
                                   msgUserName = "",
                                   msgAuthenticationParameters = "",
                                   msgPrivacyParameters = ""}),
    Hdr = #v3_hdr{msgID = MsgId, msgMaxSize = 65507,
                  msgFlags = [4],                       % reportable, noAuthNoPriv
                  msgSecurityModel = 3,                 % USM
                  msgSecurityParameters = Sec},
    Pdu = #pdu{type = 'get-request', request_id = ReqId, error_status = noError,
               error_index = 0, varbinds = []},
    list_to_binary(snmp_pdus:enc_message(
                     #message{version = 'version-3', vsn_hdr = Hdr,
                              data = #scopedPdu{contextEngineID = "", contextName = "",
                                                data = Pdu}})).

-doc "The authoritative engine id from the answer to probe `MsgId`.".
-spec parse(binary(), pos_integer()) -> {ok, string()} | error.
parse(Packet, MsgId) ->
    try snmp_pdus:dec_message_only(binary_to_list(Packet)) of
        #message{version = 'version-3',
                 vsn_hdr = #v3_hdr{msgID = MsgId, msgSecurityParameters = SP}} ->
            case snmp_pdus:dec_usm_security_parameters(SP) of
                #usmSecurityParameters{msgAuthoritativeEngineID = [_ | _] = E} -> {ok, E};
                _ -> error
            end;
        _ ->
            error
    catch
        _:_ -> error
    end.
