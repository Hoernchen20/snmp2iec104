-module(s2i_web_session).
-moduledoc """
Login sessions (docs/DESIGN.md §9.2): owner of the ETS table `s2i_web_session`.

A session token is 32 random bytes (base64url), handed out once in the
session cookie. The table is keyed by the SHA-256 of the token, so a table
dump does not reveal usable tokens. Each session expires after
`session_idle_timeout` without requests (default 30 min) and at the latest
`session_max_age` after login (default 12 h); `s2i_web` env, milliseconds.

Sessions carry only the user name: role and the forced password change are
read from `s2i_users` on every request, so changes apply at once. Deleting a
user or changing a password ends that user's (other) sessions.

Lookups and touches run in the caller (public table); only the periodic
sweep runs in this process.
""".
-behaviour(gen_server).

-export([start_link/0, child_spec/0]).
-export([create/1, lookup/1, peek/1, delete/1, delete_user/1, delete_user/2, count/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, ?MODULE).
-define(SWEEP_MS, 60000).
-define(DEFAULT_IDLE, 30 * 60 * 1000).
-define(DEFAULT_MAX_AGE, 12 * 60 * 60 * 1000).

-type token() :: binary().
-export_type([token/0]).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec child_spec() -> supervisor:child_spec().
child_spec() ->
    #{id => ?MODULE, start => {?MODULE, start_link, []}, type => worker}.

-doc "New session for `User`; the token is only known to the caller.".
-spec create(binary()) -> token().
create(User) ->
    Token = base64:encode(crypto:strong_rand_bytes(32), #{mode => urlsafe, padding => false}),
    Now = now_ms(),
    true = ets:insert(?TAB, {key(Token), User, Now, Now}),
    Token.

-doc "The session's user; refreshes the idle timer.".
-spec lookup(term()) -> {ok, binary()} | error.
lookup(Token) ->
    lookup(Token, true).

-doc """
The session's user without refreshing the idle timer (an open WebSocket
does not keep a session alive on its own).
""".
-spec peek(term()) -> {ok, binary()} | error.
peek(Token) ->
    lookup(Token, false).

lookup(Token, Touch) when is_binary(Token) ->
    Key = key(Token),
    Now = now_ms(),
    case ets:lookup(?TAB, Key) of
        [{_, User, Created, Seen}] ->
            case expired(Created, Seen, Now) of
                false ->
                    _ = Touch andalso ets:update_element(?TAB, Key, {4, Now}),
                    {ok, User};
                true ->
                    _ = ets:delete(?TAB, Key),
                    error
            end;
        [] ->
            error
    end;
lookup(_, _) ->
    error.

-spec delete(term()) -> ok.
delete(Token) when is_binary(Token) ->
    true = ets:delete(?TAB, key(Token)),
    ok;
delete(_) ->
    ok.

-doc "End all sessions of `User`.".
-spec delete_user(binary()) -> ok.
delete_user(User) ->
    _ = ets:match_delete(?TAB, {'_', User, '_', '_'}),
    ok.

-doc "End all sessions of `User` except the one of `KeepToken`.".
-spec delete_user(binary(), token()) -> ok.
delete_user(User, KeepToken) ->
    Keep = key(KeepToken),
    _ = ets:select_delete(?TAB, [{{'$1', User, '_', '_'}, [{'=/=', '$1', {const, Keep}}], [true]}]),
    ok.

-spec count() -> non_neg_integer().
count() ->
    ets:info(?TAB, size).

%%% ===========================================================================
%%% gen_server
%%% ===========================================================================

-spec init([]) -> {ok, #{}}.
init([]) ->
    _ = ets:new(?TAB, [named_table, public, set, {read_concurrency, true}, {write_concurrency, true}]),
    _ = erlang:send_after(?SWEEP_MS, self(), sweep),
    {ok, #{}}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, {error, unknown_call}, map()}.
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info(sweep, State) ->
    Now = now_ms(),
    _ = ets:foldl(fun({Key, _, Created, Seen}, ok) ->
                          _ = expired(Created, Seen, Now) andalso ets:delete(?TAB, Key),
                          ok
                  end, ok, ?TAB),
    _ = erlang:send_after(?SWEEP_MS, self(), sweep),
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

%%% ===========================================================================

key(Token) -> crypto:hash(sha256, Token).

expired(Created, Seen, Now) ->
    Now - Seen > env(session_idle_timeout, ?DEFAULT_IDLE)
        orelse Now - Created > env(session_max_age, ?DEFAULT_MAX_AGE).

env(Key, Default) -> application:get_env(s2i_web, Key, Default).

now_ms() -> erlang:monotonic_time(millisecond).
