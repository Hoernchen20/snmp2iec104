-module(s2i_reconcile_tests).
-include_lib("eunit/include/eunit.hrl").

servers_test() ->
    Running = #{<<"a">> => 1, <<"b">> => 1, <<"c">> => 1},
    Desired = #{<<"a">> => 1, <<"b">> => 2, <<"d">> => 1},
    %% b changed: restart = stop + start; every stop happens before any start
    %% (a port can move from one server to another)
    ?assertEqual(#{stop => [<<"b">>, <<"c">>], start => [{<<"b">>, 2}, {<<"d">>, 1}]},
                 s2i_reconcile:servers(Desired, Running)),
    ?assertEqual(#{stop => [], start => []}, s2i_reconcile:servers(Running, Running)).

points_test() ->
    P = fun(T) -> #{type => T, source => {datapoint, <<"x">>}} end,
    Old = #{<<"s1">> => #{{1, 10} => P(m_sp_tb_1), {1, 11} => P(m_sp_tb_1), {1, 12} => P(m_sp_tb_1)},
            <<"s2">> => #{{1, 1} => P(m_me_nc_1)}},
    New = #{<<"s1">> => #{{1, 10} => P(m_sp_tb_1),
                          {1, 11} => P(m_dp_tb_1),                                  %% type changed
                          {1, 12} => #{type => m_sp_tb_1, source => {datapoint, <<"y">>}}, %% other source
                          {1, 13} => P(m_sp_tb_1)},
            <<"s3">> => #{{2, 1} => P(m_me_nc_1)}},
    %% a changed point is removed and added again (its value no longer applies)
    ?assertEqual(#{remove => [{<<"s1">>, {1, 11}}, {<<"s1">>, {1, 12}}, {<<"s2">>, {1, 1}}],
                   add => [{<<"s1">>, {1, 11}, P(m_dp_tb_1)},
                           {<<"s1">>, {1, 12}, #{type => m_sp_tb_1, source => {datapoint, <<"y">>}}},
                           {<<"s1">>, {1, 13}, P(m_sp_tb_1)},
                           {<<"s3">>, {2, 1}, P(m_me_nc_1)}]},
                 s2i_reconcile:points(Old, New)),
    ?assertEqual(#{remove => [], add => []}, s2i_reconcile:points(New, New)).
