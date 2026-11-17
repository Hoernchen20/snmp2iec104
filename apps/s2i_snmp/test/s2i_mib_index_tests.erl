-module(s2i_mib_index_tests).
-include_lib("eunit/include/eunit.hrl").
-compile(nowarn_untyped_record).
-include_lib("snmp/include/snmp_types.hrl").

-define(IFX, [1, 3, 6, 1, 2, 1, 2, 2, 1]).

mib() ->
    Enum = #asn1_type{bertype = 'INTEGER', assocList = [{enums, [{down, 2}, {up, 1}]}], aliasname = 'INTEGER'},
    #mib{name = "T-MIB",
         mes = [#me{oid = [1, 3, 6, 1, 2, 1], entrytype = internal, aliasname = 'mib-2', imported = true},
                #me{oid = [1, 3, 6, 1, 2, 1, 2], entrytype = internal, aliasname = interfaces},
                #me{oid = [1, 3, 6, 1, 2, 1, 2, 2], entrytype = table, aliasname = ifTable,
                    access = 'not-accessible', description = "The table\n        of interfaces:\n\n          - indented\n        end  "},
                #me{oid = ?IFX, entrytype = table_entry, aliasname = ifEntry},
                #me{oid = ?IFX ++ [2], entrytype = table_column, aliasname = ifDescr,
                    asn1_type = #asn1_type{bertype = 'OCTET STRING', lo = 0, hi = 255, aliasname = 'DisplayString'},
                    access = 'read-only', units = "chars", description = [71, 114, 195, 188, 195, 159, 101]},
                #me{oid = ?IFX ++ [8], entrytype = table_column, aliasname = ifOperStatus, asn1_type = Enum,
                    access = 'read-only', description = [16#E4]}],
         traps = [#notification{trapname = linkDown, oid = [1, 3, 6, 1, 6, 3, 1, 1, 5, 3],
                                oidobjects = [{?IFX ++ [8], Enum}], description = "down"},
                  #trap{trapname = acmeTrap, enterpriseoid = [1, 3, 6, 1, 4, 1, 4242], specificcode = 7,
                        oidobjects = [], description = undefined}]}.

defs_test() ->
    Defs = s2i_mib_index:defs(<<"T-MIB">>, mib()),
    ?assertEqual([interfaces, ifTable, ifEntry, ifDescr, ifOperStatus, linkDown, acmeTrap],
                 [binary_to_atom(N) || #{name := N} <- Defs]),
    [_, Table, Entry, Descr, Oper, Down, Acme] = Defs,
    ?assertMatch(#{kind := table, access := <<"not-accessible">>,
                   description := <<"The table\nof interfaces:\n\n  - indented\nend">>}, Table),
    ?assertMatch(#{kind := row}, Entry),
    ?assertEqual(#{oid => ?IFX ++ [2], name => <<"ifDescr">>, module => <<"T-MIB">>, kind => column,
                   syntax => <<"DisplayString">>, base_type => <<"OCTET STRING">>, range => [0, 255],
                   access => <<"read-only">>, units => <<"chars">>, description => <<"Grüße"/utf8>>},
                 Descr),
    ?assertMatch(#{enums := [#{value := 1, name := <<"up">>}, #{value := 2, name := <<"down">>}],
                   description := <<"ä"/utf8>>}, Oper),
    ?assertMatch(#{kind := notification, objects := [_]}, Down),
    ?assertMatch(#{kind := notification, oid := [1, 3, 6, 1, 4, 1, 4242, 0, 7], objects := []}, Acme),
    ?assertNot(is_map_key(description, Acme)).

tables() ->
    Rfc = [#{oid => [1, 3, 6, 1, 2, 1, 2, 2], name => <<"ifTable">>, module => <<"RFC1213-MIB">>, kind => table}],
    s2i_mib_index:build(s2i_mib_index:defs(<<"T-MIB">>, mib()) ++ Rfc ++ s2i_mib_index:smi_defs()).

with_tables(F) ->
    T = tables(),
    try F(T) after s2i_mib_index:delete(T) end.

lookup_and_translate_test() ->
    with_tables(
      fun(T) ->
              %% the first definition wins for overlapping modules
              ?assertMatch({ok, #{module := <<"T-MIB">>, name := <<"ifTable">>}},
                           s2i_mib_index:lookup(T, [1, 3, 6, 1, 2, 1, 2, 2])),
              ?assertEqual(error, s2i_mib_index:lookup(T, [1, 3, 6, 1, 2, 1, 2, 2, 7])),
              ?assertMatch({ok, #{name := <<"ifOperStatus">>}, [3]}, s2i_mib_index:translate(T, ?IFX ++ [8, 3])),
              ?assertMatch({ok, #{name := <<"ifOperStatus">>}, []}, s2i_mib_index:translate(T, ?IFX ++ [8])),
              ?assertMatch({ok, #{name := <<"enterprises">>}, [9, 1]},
                           s2i_mib_index:translate(T, [1, 3, 6, 1, 4, 1, 9, 1])),
              ?assertEqual(error, s2i_mib_index:translate(T, [7, 1])),
              ?assertEqual(error, s2i_mib_index:translate(T, []))
      end).

resolve_test() ->
    with_tables(
      fun(T) ->
              ?assertEqual({ok, ?IFX ++ [8]}, s2i_mib_index:resolve(T, <<"ifOperStatus">>)),
              ?assertEqual({ok, ?IFX ++ [8, 3]}, s2i_mib_index:resolve(T, <<" T-MIB::ifOperStatus.3 ">>)),
              ?assertEqual({ok, [1, 3, 6, 1]}, s2i_mib_index:resolve(T, <<".1.3.6.1">>)),
              ?assertEqual({error, not_found}, s2i_mib_index:resolve(T, <<"X-MIB::ifOperStatus">>)),
              ?assertEqual({error, not_found}, s2i_mib_index:resolve(T, <<"nope">>)),
              ?assertEqual({error, invalid}, s2i_mib_index:resolve(T, <<"if Oper">>)),
              %% same OID in two modules is not ambiguous
              ?assertEqual({ok, [1, 3, 6, 1, 2, 1, 2, 2]}, s2i_mib_index:resolve(T, <<"ifTable">>))
      end),
    T2 = s2i_mib_index:build([#{oid => [1, 1], name => <<"x">>, module => <<"A">>, kind => node},
                              #{oid => [1, 2], name => <<"x">>, module => <<"B">>, kind => node}]),
    ?assertEqual({error, {ambiguous, [<<"A">>, <<"B">>]}}, s2i_mib_index:resolve(T2, <<"x">>)),
    ?assertEqual({ok, [1, 2]}, s2i_mib_index:resolve(T2, <<"B::x">>)),
    s2i_mib_index:delete(T2).

children_test() ->
    with_tables(
      fun(T) ->
              ?assertMatch([{[0], #{name := <<"ccitt">>}, true}, {[1], #{name := <<"iso">>}, true},
                            {[2], #{name := <<"joint-iso-ccitt">>}, false}],
                           s2i_mib_index:children(T, [])),
              ?assertMatch([{?IFX, #{name := <<"ifEntry">>}, true}],
                           s2i_mib_index:children(T, [1, 3, 6, 1, 2, 1, 2, 2])),
              ?assertMatch([{_, #{name := <<"ifDescr">>}, false}, {_, #{name := <<"ifOperStatus">>}, false}],
                           s2i_mib_index:children(T, ?IFX)),
              %% unnamed intermediate arcs: 1.3.6.1.6.3.1.1.5.3 (linkDown) below snmpModules
              ?assertMatch([{[1, 3, 6, 1, 6, 3, 1], undefined, true}],
                           s2i_mib_index:children(T, [1, 3, 6, 1, 6, 3])),
              ?assertEqual([], s2i_mib_index:children(T, [9]))
      end).

search_test() ->
    with_tables(
      fun(T) ->
              ?assertMatch([#{name := <<"ifTable">>, module := <<"T-MIB">>}],
                           s2i_mib_index:search(T, <<"IFTABLE">>, 10)),
              Names = [N || #{name := N} <- s2i_mib_index:search(T, <<"if">>, 10)],
              ?assertEqual([<<"ifDescr">>, <<"ifEntry">>, <<"ifTable">>, <<"ifOperStatus">>], Names),
              ?assertEqual(2, length(s2i_mib_index:search(T, <<"if">>, 2))),
              ?assertMatch([#{name := <<"interfaces">>}], s2i_mib_index:search(T, <<"terf">>, 10)),
              ?assertEqual([], s2i_mib_index:search(T, <<"zzz">>, 10))
      end).
