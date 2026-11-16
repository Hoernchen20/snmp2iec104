-module(s2i_iec104_client).
-moduledoc """
Minimal IEC 104 client for tests: connect + STARTDT, general interrogation,
receive ASDUs. Sequence numbers are tracked per socket (process dictionary)
and every received I-frame is acknowledged.
""".
-include_lib("iec60870/include/iec60870_asdu.hrl").

-export([connect/1, try_connect/1, gi/2, recv_asdu/1, recv_asdu/2, send_asdu/2,
         expect_no_data/2, expect_closed/2, close/1]).

connect(Port) ->
    {ok, S} = try_connect(Port),
    ok = send_frame(S, {u, startdt_act}),
    {u, startdt_con} = recv_frame(S, 2000),
    #asdu{type = m_ei_na_1} = recv_asdu(S),
    S.

try_connect(Port) ->
    case gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}, {packet, 0}], 1000) of
        {ok, S} ->
            put({ns, S}, 0),
            put({nr, S}, 0),
            {ok, S};
        Error ->
            Error
    end.

close(S) -> gen_tcp:close(S).

%% General interrogation of one COA: sorted [{Ioa, Value, Quality}].
gi(S, Coa) ->
    ok = send_asdu(S, #asdu{type = c_ic_na_1, cot = act, coa = Coa,
                            objects = [#object{ioa = 0, value = 20}]}),
    #asdu{type = c_ic_na_1, cot = act_con, negative = false} = recv_asdu(S),
    gi_dump(S, []).

gi_dump(S, Acc) ->
    case recv_asdu(S) of
        #asdu{type = c_ic_na_1, cot = act_term} ->
            lists:sort(Acc);
        #asdu{objects = Objs} ->
            gi_dump(S, [{O#object.ioa, O#object.value, lists:sort(O#object.quality)} || O <- Objs] ++ Acc)
    end.

send_asdu(S, Asdu) ->
    NS = get({ns, S}),
    put({ns, S}, (NS + 1) rem 32768),
    send_frame(S, {i, NS, get({nr, S}), iec60870_asdu:encode(Asdu)}).

recv_asdu(S) -> recv_asdu(S, 3000).

recv_asdu(S, Timeout) ->
    case recv_frame(S, Timeout) of
        {i, _NS, _NR, Bin} ->
            NR = (get({nr, S}) + 1) rem 32768,
            put({nr, S}, NR),
            ok = send_frame(S, {s, NR}),
            {ok, Asdu, <<>>} = iec60870_asdu:decode(Bin),
            Asdu;
        {u, testfr_act} ->
            ok = send_frame(S, {u, testfr_con}),
            recv_asdu(S, Timeout);
        Other ->
            error({expected_i_frame, Other})
    end.

expect_no_data(S, Timeout) ->
    case gen_tcp:recv(S, 0, Timeout) of
        {error, timeout} -> ok;
        {ok, Data} -> error({unexpected_data, Data})
    end.

expect_closed(S, Timeout) ->
    case gen_tcp:recv(S, 0, Timeout) of
        {error, closed} -> ok;
        Other -> error({expected_closed, Other})
    end.

send_frame(S, Frame) ->
    gen_tcp:send(S, iec60870_104_apci:encode(Frame)).

recv_frame(S, Timeout) ->
    {ok, <<16#68, Len>>} = gen_tcp:recv(S, 2, Timeout),
    {ok, Body} = gen_tcp:recv(S, Len, Timeout),
    {ok, Frame, <<>>} = iec60870_104_apci:decode(<<16#68, Len, Body/binary>>),
    Frame.
