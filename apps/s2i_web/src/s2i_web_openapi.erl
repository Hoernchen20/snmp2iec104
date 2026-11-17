-module(s2i_web_openapi).
-moduledoc """
OpenAPI 3.1 description of `/api/v1`, served at `GET /api/v1/openapi.json`
and used to generate the TypeScript client types of the UI
(`frontend/src/api/schema.d.ts`, `npm run gen:api`).

The entity schemas (`Server`, `Device`, `Profile`) are generated from
`s2i_schema` (`json_schema/1`); the paths here follow `s2i_web_rest:routes/0`,
which a test checks.
""".

-export([spec/0, operations/0]).

-spec spec() -> map().
spec() ->
    #{openapi => <<"3.1.0">>,
      info => #{title => <<"snmp2iec104 REST API">>, version => <<"1">>},
      servers => [#{url => <<"/api/v1">>}],
      components => #{schemas => schemas(),
                      securitySchemes => #{session => #{type => apiKey, in => cookie,
                                                        name => s2i_web_api:cookie_name()}},
                      parameters => #{csrf => #{name => <<"X-Requested-With">>, in => header,
                                                required => true, schema => #{type => string},
                                                description => <<"required on every request except GET/HEAD">>}}},
      security => [#{session => []}],
      paths => paths()}.

-doc "`{Path, Method}` of every documented operation (for the route test).".
-spec operations() -> [{binary(), binary()}].
operations() ->
    lists:sort([{P, string:uppercase(atom_to_binary(M))} || P := Ops <- paths(), M := _ <- Ops]).

%%% ===========================================================================

schemas() ->
    #{'Server' => s2i_schema:json_schema(server),
      'Device' => s2i_schema:json_schema(device),
      'Profile' => s2i_schema:json_schema(profile),
      'Config' => #{type => object, required => [servers, devices, profiles],
                    properties => #{servers => map_of(ref('Server')),
                                    devices => map_of(ref('Device')),
                                    profiles => map_of(ref('Profile'))}},
      'Error' => #{type => object, required => [error],
                   properties => #{error => #{type => string},
                                   errors => #{type => array, items => ref('SchemaError')}}},
      'SchemaError' => #{type => object, required => [path, error],
                         properties => #{path => #{type => array,
                                                   items => #{oneOf => [#{type => string}, #{type => integer}]}},
                                         error => #{type => string},
                                         detail => #{type => object}}},
      'Me' => #{type => object, required => [name, role, must_change_password],
                properties => #{name => #{type => string}, role => role(),
                                must_change_password => #{type => boolean}}},
      'User' => #{type => object, required => [name, role, must_change_password, created_at, updated_at],
                  properties => #{name => #{type => string}, role => role(),
                                  must_change_password => #{type => boolean},
                                  created_at => ms(), updated_at => ms()}},
      'UserInput' => #{type => object, additionalProperties => false,
                       properties => #{role => role(),
                                       password => #{type => string, minLength => 8, writeOnly => true},
                                       must_change_password => #{type => boolean}},
                       description => <<"role and password are required when creating a user">>},
      'Version' => #{type => object, required => [vsn, at, author, comment],
                     properties => #{vsn => #{type => integer}, at => ms(), author => #{type => string},
                                     comment => #{type => string}}},
      'AuditEntry' => #{type => object, required => [id, at, actor, action],
                        properties => #{id => #{type => integer}, at => ms(), actor => #{type => string},
                                        action => #{type => string}, kind => #{type => string},
                                        name => #{type => string}, vsn => #{type => integer}}},
      'Validation' => #{type => object, required => [valid, server_restarts],
                        properties => #{valid => #{type => boolean}, has_changes => #{type => boolean},
                                        errors => #{type => array, items => ref('SchemaError')},
                                        server_restarts => #{type => array, items => #{type => string},
                                                             description => <<"IEC servers the activation "
                                                                              "restarts (drops connections)">>}}},
      'DeviceStatus' => #{type => object, required => [name, enabled, health],
                          properties => #{name => #{type => string}, enabled => #{type => boolean},
                                          health => #{type => string,
                                                      enum => [unknown, up, degraded, down, disabled, not_running]},
                                          registered => #{type => boolean},
                                          failures => #{type => integer}, overruns => #{type => integer},
                                          cycles => #{type => integer}, last_ok => #{oneOf => [ms(), #{const => null}]},
                                          traps => #{type => integer}, unmatched => #{type => integer},
                                          resolved => #{type => object},
                                          unresolved => #{type => array, items => #{type => string}},
                                          error => #{}}},
      'ServerStatus' => #{type => object, required => [name, state, points, groups],
                          properties => #{name => #{type => string},
                                          state => #{type => string, enum => [running, start_failed, not_running]},
                                          points => #{type => integer},
                                          groups => #{type => array, items => ref('GroupStatus')}}},
      'GroupStatus' => #{type => object, required => [name, active, members, buffer_len],
                         description => <<"redundancy group of a running server">>,
                         properties => #{name => #{type => string,
                                                   description => <<"configured name, `default`, or "
                                                                    "`connection` (one group per connection)">>},
                                         active => #{type => boolean,
                                                     description => <<"a connection is the active one (STARTDT)">>},
                                         members => #{type => integer, description => <<"open connections">>},
                                         buffer_len => #{type => integer,
                                                         description => <<"ASDUs not yet acknowledged">>}}},
      'Varbind' => #{type => object, required => [oid, type, value],
                     properties => #{oid => #{type => string}, type => #{type => string},
                                     value => #{description => <<"integer, text, dotted OID / address, an "
                                                                 "exception name, or null for binary octets">>},
                                     hex => #{type => string, description => <<"octet strings only">>}}}}.

paths() ->
    Name = param(name, path, string),
    Entity = fun(Tag, Schema) ->
                     Ref = ref(Schema),
                     {#{get => op(Tag, <<"Staged ", Tag/binary, " (sorted by name)">>, [],
                                  undefined, ok(#{type => array, items => Ref}))},
                      #{get => op(Tag, <<"One staged entity">>, [Name], undefined, ok(Ref)),
                        put => op(Tag, <<"Create or replace (admin); schema-checked, references are checked "
                                         "on validate/activate">>, [Name], Ref, ok(Ref)),
                        delete => op(Tag, <<"Delete (admin)">>, [Name], undefined, none())}}
             end,
    {Servers, Server} = Entity(<<"servers">>, 'Server'),
    {Devices, Device} = Entity(<<"devices">>, 'Device'),
    {Profiles, Profile} = Entity(<<"profiles">>, 'Profile'),
    Vsn = param(vsn, path, integer),
    #{<<"/login">> =>
          #{post => (op(<<"session">>, <<"Log in; sets the session cookie">>, [],
                        obj([username, password]), ok(ref('Me'))))#{security => []}},
      <<"/logout">> => #{post => op(<<"session">>, <<"End the session">>, [], undefined, none())},
      <<"/me">> => #{get => op(<<"session">>, <<"The logged-in user">>, [], undefined, ok(ref('Me')))},
      <<"/me/password">> =>
          #{post => op(<<"session">>, <<"Change the own password (ends the user's other sessions)">>, [],
                       obj([current_password, new_password]), ok(ref('Me')))},
      <<"/openapi.json">> =>
          #{get => (op(<<"meta">>, <<"This document">>, [], undefined, ok(#{type => object})))#{security => []}},
      <<"/servers">> => Servers, <<"/servers/{name}">> => Server,
      <<"/devices">> => Devices, <<"/devices/{name}">> => Device,
      <<"/profiles">> => Profiles, <<"/profiles/{name}">> => Profile,
      <<"/users">> => #{get => op(<<"users">>, <<"All users (admin)">>, [], undefined,
                                  ok(#{type => array, items => ref('User')}))},
      <<"/users/{name}">> =>
          #{get => op(<<"users">>, <<"One user (admin)">>, [Name], undefined, ok(ref('User'))),
            put => op(<<"users">>, <<"Create or update (admin); a password set for someone else must be "
                                     "changed on their next login">>, [Name], ref('UserInput'), ok(ref('User'))),
            delete => op(<<"users">>, <<"Delete (admin); not the last admin">>, [Name], undefined, none())},
      <<"/config/staged">> =>
          #{get => op(<<"config">>, <<"The staged configuration">>, [], undefined,
                      ok(#{type => object, properties => #{config => ref('Config'),
                                                           has_changes => #{type => boolean}}}))},
      <<"/config/active">> =>
          #{get => op(<<"config">>, <<"The active configuration (404 before the first activation)">>, [],
                      undefined, ok(versioned()))},
      <<"/config/validate">> =>
          #{post => op(<<"config">>, <<"Validate the staged configuration">>, [], undefined, ok(ref('Validation')))},
      <<"/config/activate">> =>
          #{post => op(<<"config">>, <<"Validate and activate the staged configuration (admin)">>, [],
                       #{type => object, properties => #{comment => #{type => string}}},
                       ok(#{type => object, properties => #{vsn => #{type => integer}}}))},
      <<"/config/revert">> =>
          #{post => op(<<"config">>, <<"Discard staged changes (admin)">>, [], undefined, none())},
      <<"/config/export">> =>
          #{get => op(<<"config">>, <<"Staged or active configuration for backup (secrets as envelopes)">>,
                      [(param(source, query, string))#{schema => #{type => string, enum => [staged, active],
                                                                   default => staged}}],
                      undefined, ok(ref('Config')))},
      <<"/config/import">> =>
          #{post => op(<<"config">>, <<"Replace the staged configuration (admin)">>, [], ref('Config'), none())},
      <<"/config/audit">> =>
          #{get => op(<<"config">>, <<"Newest audit entries first">>,
                      [(param(limit, query, integer))#{schema => #{type => integer, minimum => 0,
                                                                   maximum => 10000, default => 100}}],
                      undefined, ok(#{type => array, items => ref('AuditEntry')}))},
      <<"/config/versions">> =>
          #{get => op(<<"config">>, <<"Activated versions, newest first">>, [], undefined,
                      ok(#{type => array, items => ref('Version')}))},
      <<"/config/versions/{vsn}">> =>
          #{get => op(<<"config">>, <<"One activated version">>, [Vsn], undefined, ok(versioned()))},
      <<"/config/versions/{vsn}/restore">> =>
          #{post => op(<<"config">>, <<"Load a version into the staged configuration (admin); "
                                       "activate to roll back">>, [Vsn], undefined, none())},
      <<"/status">> =>
          #{get => op(<<"status">>, <<"Devices, servers, active version">>, [], undefined,
                      ok(#{type => object,
                           properties => #{devices => #{type => array, items => ref('DeviceStatus')},
                                           servers => #{type => array, items => ref('ServerStatus')},
                                           active_vsn => #{oneOf => [#{type => integer}, #{const => null}]},
                                           has_changes => #{type => boolean}}}))},
      <<"/status/devices">> =>
          #{get => op(<<"status">>, <<"Devices of the active configuration">>, [], undefined,
                      ok(#{type => array, items => ref('DeviceStatus')}))},
      <<"/status/devices/{name}">> =>
          #{get => op(<<"status">>, <<"One device">>, [Name], undefined, ok(ref('DeviceStatus')))},
      <<"/status/servers">> =>
          #{get => op(<<"status">>, <<"IEC servers of the active configuration">>, [], undefined,
                      ok(#{type => array, items => ref('ServerStatus')}))},
      <<"/tools/snmp/get">> =>
          #{post => op(<<"tools">>, <<"GET through a configured, running device (at most max_varbinds OIDs)">>,
                       [], #{type => object, required => [device, oids],
                             properties => #{device => #{type => string},
                                             oids => #{type => array, minItems => 1,
                                                       items => #{type => string}}}},
                       ok(#{type => object, properties => #{varbinds => #{type => array, items => ref('Varbind')}}}))},
      <<"/tools/snmp/walk">> =>
          #{post => op(<<"tools">>, <<"Walk a subtree through a configured, running device">>, [],
                       #{type => object, required => [device, oid],
                         properties => #{device => #{type => string}, oid => #{type => string},
                                         max => #{type => integer, minimum => 1, maximum => 10000,
                                                  default => 1000}}},
                       ok(#{type => object, properties => #{varbinds => #{type => array, items => ref('Varbind')},
                                                            truncated => #{type => boolean}}}))}}.

op(Tag, Summary, Params, Body, Responses) ->
    Op = #{tags => [Tag], summary => Summary,
           responses => Responses#{default => #{description => <<"error">>,
                                                content => json(ref('Error'))}}},
    Op1 = case Params of
              [] -> Op;
              _ -> Op#{parameters => Params}
          end,
    case Body of
        undefined -> Op1;
        _ -> Op1#{requestBody => #{required => true, content => json(Body)}}
    end.

ok(Schema) -> #{'200' => #{description => <<"OK">>, content => json(Schema)}}.
none() -> #{'204' => #{description => <<"done">>}}.
json(Schema) -> #{<<"application/json">> => #{schema => Schema}}.
ref(Name) -> #{'$ref' => <<"#/components/schemas/", (atom_to_binary(Name))/binary>>}.
map_of(Schema) -> #{type => object, additionalProperties => Schema}.
role() -> #{type => string, enum => [admin, viewer]}.
ms() -> #{type => integer, description => <<"Unix time in milliseconds">>}.
obj(Required) -> #{type => object, required => Required,
                   properties => maps:from_keys(Required, #{type => string})}.
versioned() -> #{type => object, properties => #{vsn => #{type => integer}, config => ref('Config')}}.

param(Name, In, Type) ->
    #{name => Name, in => In, required => In =:= path, schema => #{type => Type}}.
