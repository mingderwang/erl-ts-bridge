%%%-------------------------------------------------------------------
%%% @doc Supervises the acceptor pool and owns the shared connection
%%% counter.
%%%
%%% All acceptors bind the same port with `SO_REUSEPORT' when enabled, so
%%% the kernel spreads incoming connections across them. The listening
%%% socket is opened <em>once</em>, here, before the children start, and
%%% the file descriptor is handed to each acceptor.
%%%
%%% That ordering is the whole point of this module. If each acceptor
%%% opened its own socket, a port conflict would show up as a child crash
%%% report and a supervisor restart loop -- an unbounded, noisy retry
%%% against a port that is genuinely in use by something else. Binding
%%% once, up front, means a conflict is a single `eaddrinuse' returned to
%%% the caller and nothing starts.
%%% @end
%%%-------------------------------------------------------------------
-module(erl_bridge_acceptor_sup).

-behaviour(supervisor).

-include("erl_bridge.hrl").

-export([start_link/1, acceptor_count/1, connection_count/0]).

-export([init/1, terminate/1]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link(erl_bridge_config:cfg()) -> {ok, pid()} | {error, term()}.
start_link(Cfg) ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, [Cfg]).

%% @doc How many acceptors this configuration asks for.
-spec acceptor_count(erl_bridge_config:cfg()) -> pos_integer().
acceptor_count(#cfg{acceptor_count = undefined}) ->
    erl_bridge_config:default_acceptor_count();
acceptor_count(#cfg{acceptor_count = N}) ->
    N.

%% @doc Live connection count across all acceptors. For tests, and for
%% a caller that wants to wait for a graceful drain before exiting.
-spec connection_count() -> non_neg_integer().
connection_count() ->
    try atomics:get(persistent_term:get({?SERVER, conns}), 1)
    catch _:_ -> 0
    end.

%%%===================================================================
%%% supervisor
%%%===================================================================

init([Cfg]) ->
    Count = acceptor_count(Cfg),
    case erl_bridge_acceptor:listen_options(Cfg) of
        {ok, ListenSocket} ->
            %% Written back so that a listener opened on port 0 reports
            %% the port the OS actually assigned. Without this the
            %% published config would keep saying 0, and a caller reading
            %% it would have no way to find the server.
            ActualPort = erl_bridge_transport:port(ListenSocket),
            Cfg1 = Cfg#cfg{port = ActualPort},
            application:set_env(?APP, resolved_config, Cfg1),
            %% One shared counter. A per-acceptor counter would multiply
            %% the configured cap by the acceptor count.
            Conns = atomics:new(1, [{signed, false}]),
            %% Published so connection_count/0 can read it without going
            %% through the supervisor.
            persistent_term:put({?SERVER, conns}, Conns),
            %% The listening socket is owned here, not by the acceptors:
            %% they all share this one descriptor, so whichever of them
            %% closed it would break the others' accept loops. Stashed in
            %% the process dictionary because init/1 and terminate/1 both
            %% run in this process and a supervisor has no state field to
            %% put it in.
            put(listen_socket, ListenSocket),
            logger:info("erl_bridge listening: ~s",
                        [erl_bridge_config:describe(Cfg1)]),
            warn_if_unauthenticated(Cfg1),
            Children =
                [#{id => {acceptor, N},
                   %% self() here is the supervisor: the child spec is
                   %% evaluated in the supervisor process, so each
                   %% acceptor learns who to honour a shutdown EXIT from.
                   start => {erl_bridge_acceptor, start_link,
                             [ListenSocket, Cfg1, Conns, self()]},
                   %% A crashed acceptor is restarted, not fatal: losing
                   %% one leaves the others accepting, and the kernel
                   %% redistributes its backlog. Requiring a majority
                   %% would take the whole server down for a single
                   %% failure.
                   restart => permanent,
                   shutdown => Cfg1#cfg.shutdown_grace,
                   type => worker,
                   modules => [erl_bridge_acceptor]}
                 || N <- lists:seq(1, Count)],
            {ok, {#{strategy => one_for_one, intensity => 5, period => 10},
                  Children}};
        {error, Reason} ->
            {stop, {listen_failed, Cfg#cfg.port, Reason}}
    end.

%% "Authentication is off" is a legitimate choice on a trusted network,
%% but it must never be silent.
warn_if_unauthenticated(#cfg{token = undefined}) ->
    logger:warning("erl_bridge: authentication DISABLED -- any peer that "
                   "connects can send requests. Set ERL_BRIDGE_TOKEN or "
                   "the `token' application environment key to enable it.");
warn_if_unauthenticated(#cfg{}) ->
    ok.

%% Runs after every acceptor child has terminated, which is exactly when
%% the shared listening socket can safely be closed. Also clears the
%% published counter, so a stopped server does not leave a dangling
%% reference for connection_count/0 to trip over.
terminate(_Reason) ->
    case erase(listen_socket) of
        undefined -> ok;
        ListenSocket -> erl_bridge_transport:close(ListenSocket)
    end,
    _ = persistent_term:erase({?SERVER, conns}),
    ok.
