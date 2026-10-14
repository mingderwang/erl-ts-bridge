%%%-------------------------------------------------------------------
%%% @doc Accepts connections and hands each to a worker.
%%%
%%% <b>Why this is a plain process and not a `gen_server'.</b> An earlier
%%% version drove the accept loop from a `gen_server', using a 0 ms
%%% timeout message to re-arm the callback between accepts. It served a
%%% connection or two and then silently stopped accepting -- parked in the
%%% receive loop, no pending message, no error anywhere. A failure like
%%% that is close to undiagnosable in the field. A plain `receive' with an
%%% `after' clause does the same job with no moving parts: drain control
%%% messages, do at most one bounded accept, recurse.
%%%
%%% The price is that shutdown latency is one accept timeout (~1 s by
%%% default) rather than immediate, and the acceptor cannot be inspected
%%% with `sys:get_status/1'. Both are acceptable; a listener that silently
%%% stops accepting is not.
%%%
%%% Concurrency model, unchanged: N acceptors each holding a listening
%%% socket bound to the same port with `SO_REUSEPORT', one worker per
%%% connection, and a <em>shared</em> `atomics' counter capping workers
%%% across all of them.
%%% @end
%%%-------------------------------------------------------------------
-module(erl_bridge_acceptor).

-include("erl_bridge.hrl").

-export([start_link/4, listen_options/1, stop/1]).

-export([init/4]).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Start an acceptor.
%%
%% Returns `{ok, Pid}'. The process is linked to the caller, so a crash is
%% reported to the supervisor rather than vanishing silently.
-spec start_link(erl_bridge_transport:socket(),
                 erl_bridge_config:cfg(), atomics:atomics_ref(), pid()) ->
                        {ok, pid()}.
start_link(ListenSocket, Cfg, Conns, Parent) ->
    Pid = spawn_link(fun() -> init(ListenSocket, Cfg, Conns, Parent) end),
    {ok, Pid}.

-spec stop(pid()) -> ok.
stop(Pid) ->
    Pid ! stop,
    ok.

%% @doc Open the listening socket.
%%
%% Separated from the acceptor process so a port conflict is reported to
%% the caller -- see erl_bridge_acceptor_sup.
-spec listen_options(erl_bridge_config:cfg()) ->
                             {ok, erl_bridge_transport:socket()} | {error, term()}.
listen_options(Cfg) ->
    erl_bridge_transport:listen(Cfg#cfg.port, Cfg).

%%%===================================================================
%%% The accept loop
%%%===================================================================

init(ListenSocket, Cfg, Conns, Parent) ->
    %% Trapped so a *worker* crash cannot take the listener down with it.
    %% The supervisor's shutdown therefore arrives as an ordinary message
    %% and has to be acted on explicitly -- see loop/4.
    process_flag(trap_exit, true),
    logger:info("acceptor ~p started on port ~p (parent ~p)",
                [self(), Cfg#cfg.port, Parent]),
    loop(ListenSocket, Cfg, Conns, Parent, 0).

%% One iteration: drain control messages, then do at most one bounded
%% accept.
%%
%% `Active' is this acceptor's own tally, used only for the log line. The
%% cap itself is enforced against the shared counter, so a stale local
%% value cannot cause the limit to be exceeded.
loop(ListenSocket, Cfg, Conns, Parent, Active) ->
    receive
        stop ->
            shutdown(ListenSocket);
        {'EXIT', Parent, _Reason} ->
            %% The supervisor is shutting us down. Because exits are
            %% trapped this arrives as a message, so swallowing it (or
            %% letting it fall through) would hang application:stop/1.
            shutdown(ListenSocket);
        {'EXIT', _Worker, _Reason} ->
            %% A connection worker died; the monitor does the accounting.
            loop(ListenSocket, Cfg, Conns, Parent, Active);
        {'DOWN', _Ref, process, _Pid, _Reason} ->
            %% A worker finished; release its slot in the shared counter.
            %%
            %% The DOWN performs the release, not the EXIT: both fire for
            %% a linked worker, and acting on both would decrement twice
            %% and let the cap be overshot. The monitor also still fires
            %% when a worker is killed with `exit(Pid, kill)', which a
            %% link alone would not report.
            atomics:sub(Conns, 1, 1),
            loop(ListenSocket, Cfg, Conns, Parent, dec(Active))
    after 0 ->
            %% `after 0' deliberately. The receive exists only to drain
            %% control messages; the accept below is what waits. Giving
            %% this clause the accept timeout as well makes every
            %% iteration wait twice, capping the listener at roughly one
            %% connection per two seconds.
            case erl_bridge_transport:accept(ListenSocket,
                                             Cfg#cfg.accept_timeout) of
                {ok, Socket} ->
                    Started = dispatch(Socket, Cfg, Conns),
                    loop(ListenSocket, Cfg, Conns, Parent, inc(Started, Active));
                {error, timeout} ->
                    loop(ListenSocket, Cfg, Conns, Parent, Active);
                {error, closed} ->
                    %% The listening socket was closed underneath us.
                    ok;
                {error, Reason} ->
                    %% Usually `emfile': the node is out of file
                    %% descriptors. Retrying immediately would pin this
                    %% process at 100% CPU and flood the log, so back off.
                    %% Without this a transient fd exhaustion becomes a
                    %% self-sustaining denial of service.
                    logger:warning("accept error: ~p -- backing off 100ms",
                                   [Reason]),
                    timer:sleep(100),
                    loop(ListenSocket, Cfg, Conns, Parent, Active)
            end
    end.

shutdown(ListenSocket) ->
    logger:info("acceptor ~p stopped", [self()]),
    %% The listening socket is deliberately NOT closed here.
    %%
    %% Every acceptor holds the *same* socket -- bound once by
    %% erl_bridge_acceptor_sup and shared through SO_REUSEPORT -- so
    %% closing it here would tear down the other acceptors' accept loops
    %% mid-flight. That surfaced as `shutdown_error' reports with reason
    %% `normal' during an otherwise clean stop. erl_bridge_acceptor_sup
    %% owns the socket and closes it once, after every acceptor is gone.
    _ = ListenSocket,
    %% Exit with `shutdown', not `normal'. A supervisor that asked a child
    %% to stop expects that reason and reports a shutdown_error for
    %% anything else -- which would put a misleading error in the log on
    %% every clean shutdown.
    exit(shutdown).

%%%===================================================================
%%% Internal
%%%===================================================================

%% Returns true when a worker was actually started, so the local tally can
%% be adjusted.
dispatch(Socket, #cfg{max_connections = Limit} = Cfg, Conns) ->
    case acquire(Conns, Limit) of
        full ->
            %% Closed rather than queued: without a queue the cap could be
            %% consumed entirely by peers that connect and never speak.
            erl_bridge_metrics:counter(connections_rejected_cap, 1),
            erl_bridge_transport:close(Socket),
            false;
        acquired ->
            spawn_worker(Socket, Cfg),
            true
    end.

%% The connection process is a real `gen_server' linked to this acceptor,
%% not a throwaway that spawns one. The socket is delivered in a message
%% after ownership has been transferred, so the worker never touches a
%% socket it does not yet own.
spawn_worker(Socket, Cfg) ->
    case erl_bridge_conn:start_link(Cfg, self()) of
        {ok, Pid} ->
            %% Monitor as well as link: a monitor is how the slot is
            %% reclaimed, and unlike a link it also fires for a worker
            %% killed with `exit(Pid, kill)'.
            erlang:monitor(process, Pid),
            case erl_bridge_transport:controlling_process(Socket, Pid) of
                ok ->
                    erl_bridge_metrics:counter(connections_accepted, 1),
                    Pid ! {socket, Socket};
                {error, Reason} ->
                    logger:warning("controlling_process failed: ~p", [Reason]),
                    erl_bridge_transport:close(Socket),
                    %% Stopping the worker produces 'DOWN', which releases
                    %% the slot -- so this path needs no separate
                    %% accounting.
                    exit(Pid, kill)
            end;
        {error, Reason} ->
            logger:warning("could not start connection worker: ~p", [Reason]),
            erl_bridge_transport:close(Socket)
    end.

%% Compare-and-exchange, so two acceptors racing for the last slot cannot
%% both observe it as free and overshoot the cap.
acquire(Conns, Limit) ->
    case atomics:get(Conns, 1) of
        N when N < Limit ->
            case atomics:compare_exchange(Conns, 1, N, N + 1) of
                ok -> acquired;
                _ -> acquire(Conns, Limit)
            end;
        _AtLimit ->
            full
    end.

inc(true, N) -> N + 1;
inc(false, N) -> N.
dec(0) -> 0;
dec(N) -> N - 1.
