%%%-------------------------------------------------------------------
%%% @doc One connection, as a `gen_server'.
%%%
%%% State is an explicit two-phase machine: a connection starts in
%%% `awaiting_hello', moves to `ready' once the HELLO exchange is
%%% accepted, and then serves requests one at a time until the peer goes
%%% away or misbehaves. No request is served before the handshake
%%% completes, which is what makes "v1 is no longer accepted" enforceable
%%% rather than aspirational.
%%%
%%% <b>Why a gen_server and not a bare process?</b> Because the
%%% supervisor needs somewhere to deliver a shutdown request, and because
%%% a wedged connection should be addressable rather than being an
%%% anonymous pid in a mailbox.
%%%
%%% <b>The loop must yield.</b> Each step performs at most one receive and
%%% returns to the gen_server loop, re-armed with a 0 ms timeout. An
%%% obvious-looking `serve(State) -> ... serve(State)' recursion inside a
%%% callback never returns to the loop, so no message is ever processed:
%%% the acceptor's shutdown signal is never seen, the connection outlives
%%% the server, and a monitor 'DOWN' that should release a slot never
%%% arrives. Yielding between receives is what makes this process
%%% actually supervisable.
%%%
%%% <b>Deadlines, not single blocking receives.</b> A request deadline of
%%% 30 s implemented as one `gen_tcp:recv(S, 0, 30000)' would also make
%%% shutdown take up to 30 s. Instead each receive is bounded by
%%% `min(remaining, ?POLL_INTERVAL)' against a monotonic deadline, so the
%%% deadline is still enforced exactly while shutdown latency stays near
%%% one poll interval.
%%%
%%% <b>Exit reasons.</b> Every connection-level termination -- a malformed
%%% handshake, a wrong version, a rejected token, a bad opcode, an idle
%%% timeout, a peer that vanishes -- exits `normal'. Those are ordinary
%%% events on a network server, and exiting abnormally would emit a crash
%%% report and a linked exit signal for every bad client. The acceptor
%%% traps exits regardless, so even a genuine fault here cannot take down
%%% the listener. The reason is not discarded: it goes into a metric and a
%%% telemetry event before stopping. Exit reasons are left for things that
%%% indicate a bug -- the only one remaining here is
%%% `no_socket_handed_over'.
%%% @end
%%%-------------------------------------------------------------------
-module(erl_bridge_conn).

-behaviour(gen_server).

-include("erl_bridge.hrl").

-export([start_link/2]).

-export([init/1, handle_continue/2, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-define(POLL_INTERVAL, 1000).

-record(state, {socket :: erl_bridge_transport:socket() | undefined,
                cfg :: erl_bridge_config:cfg(),
                parent :: pid(),
                peer :: undefined | string(),
                phase = awaiting_socket
                        :: awaiting_socket | awaiting_hello | ready,
                deadline = 0 :: integer()}).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Start a connection worker.
%%
%% Takes no socket: `gen_tcp:controlling_process/2' must be called by the
%% current owner, so the acceptor starts this process, transfers
%% ownership, and only then sends `{socket, Socket}'. The worker blocks
%% until that arrives, which guarantees it never touches a socket it does
%% not yet own.
-spec start_link(erl_bridge_config:cfg(), pid()) ->
                        {ok, pid()} | {error, term()}.
start_link(Cfg, Parent) ->
    gen_server:start_link(?MODULE, [Cfg, Parent], []).

%%%===================================================================
%%% gen_server
%%%===================================================================

init([Cfg, Parent]) ->
    %% Trapped so a worker exiting abnormally cannot kill the acceptor --
    %% but that means the acceptor's shutdown arrives as a message that
    %% has to be acted on. See handle_info/2.
    process_flag(trap_exit, true),
    {ok, #state{cfg = Cfg, parent = Parent}, {continue, await_socket}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_continue(await_socket, State) ->
    case receive_socket() of
        {ok, Socket} -> {noreply, begin_handshake(Socket, State), 0};
        timeout -> {stop, no_socket_handed_over, State}
    end.

%% The acceptor is going away, so this connection is too.
handle_info({'EXIT', Parent, Reason}, #state{parent = Parent} = State) ->
    {stop, Reason, State};
%% Each step performs at most one receive, and the loop is re-armed here.
%% The re-arm must happen even when a step returns {noreply, _} -- the
%% poll-slice case -- or the worker parks after one slice and never looks
%% at the socket again.
handle_info(timeout, State) ->
    case step(State) of
        {noreply, State1} -> {noreply, State1, 0};
        Stop -> Stop
    end;
handle_info(_Info, State) ->
    {noreply, State}.

%% This process owns the socket ({active, false} means the owner receives
%% every message for it), so closing it here is what actually closes the
%% connection. terminate/2 runs on every normal stop path.
terminate(_Reason, #state{socket = undefined}) ->
    ok;
terminate(_Reason, #state{socket = Socket}) ->
    erl_bridge_transport:close(Socket),
    erl_bridge_metrics:adjust(connections_active, -1),
    erl_bridge_metrics:counter(connections_closed, 1),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal: socket handover
%%%===================================================================

%% The acceptor sends this the moment it has transferred ownership.
%%
%% The returned socket is *consumed* here, so it must be put into the
%% state by the caller -- discarding it and waiting again in handle_info
%% leaves the worker blocked in the gen_server loop forever, holding a
%% connection slot with no socket and no deadline.
receive_socket() ->
    receive
        {socket, Socket} -> {ok, Socket}
    after 5000 ->
        timeout
    end.

begin_handshake(Socket, #state{cfg = #cfg{handshake_timeout = Timeout}} = State) ->
    Peer = erl_bridge_transport:peername(Socket),
    erl_bridge_metrics:adjust(connections_active, 1),
    telemetry:execute([erl_bridge, connection, open],
                      #{peer => Peer, tls => is_tls(Socket)}),
    State#state{socket = Socket, peer = Peer, phase = awaiting_hello,
                deadline = now_ms() + Timeout}.

%%%===================================================================
%%% Internal: the state machine
%%%===================================================================

step(#state{phase = awaiting_hello} = State) ->
    case wait_for_frame(State) of
        {frame, Hello} -> on_hello(Hello, State);
        idle -> on_idle(State);
        gone -> {stop, normal, State};
        {socket_error, Reason} -> on_socket_error(Reason, State);
        {await, State1} -> {noreply, State1}
    end;
step(#state{phase = ready} = State) ->
    case wait_for_frame(State) of
        {frame, Payload} -> on_request(Payload, State);
        idle -> on_idle(State);
        gone -> {stop, normal, State};
        {socket_error, Reason} -> on_socket_error(Reason, State);
        {await, State1} -> {noreply, State1}
    end.

on_hello(Hello, #state{cfg = #cfg{token = Configured}} = State) ->
    case erl_bridge_proto:decode_hello(Hello) of
        {error, Reason} ->
            erl_bridge_metrics:counter(handshake_malformed, 1),
            telemetry:execute([erl_bridge, handshake, failure],
                              #{reason => Reason, peer => State#state.peer}),
            {stop, normal, State};
        {ok, #{version := Version, token := Presented}} ->
            case negotiate(Version, Presented, Configured, State) of
                {ok, Ack} ->
                    erl_bridge_metrics:counter(handshake_ok, 1),
                    telemetry:execute([erl_bridge, handshake, success],
                                      #{version => Version,
                                        peer => State#state.peer}),
                    case send(State#state.socket, Ack) of
                        ok ->
                            {noreply, await_request(State#state{phase = ready})};
                        {error, _} ->
                            {stop, normal, State}
                    end;
                {reject, Ack} ->
                    %% Tell the peer why before dropping it, so a rejected
                    %% client gets a usable error rather than an
                    %% unexplained close. The result is ignored: we are
                    %% stopping either way.
                    _ = send(State#state.socket, Ack),
                    {stop, normal, State}
            end
    end.

%% Rejects in the order a client would care about: version first, because
%% a client speaking the wrong version cannot meaningfully be
%% authenticated, and reporting "auth failed" to a v1 client would be
%% misleading.
negotiate(Version, Presented, Configured, State) ->
    case erl_bridge_proto:is_supported_version(Version) of
        false ->
            erl_bridge_metrics:counter(handshake_bad_version, 1),
            telemetry:execute([erl_bridge, handshake, failure],
                              #{reason => version_unsupported,
                                version => Version,
                                peer => State#state.peer}),
            {reject, erl_bridge_proto:encode_hello_ack(0, ?HELLO_BAD_VERSION)};
        true ->
            case erl_bridge_token:verify(Configured, Presented) of
                true ->
                    warn_if_token_ignored(Configured, Presented, State),
                    {ok, erl_bridge_proto:encode_hello_ack(Version, ?HELLO_OK)};
                false ->
                    erl_bridge_metrics:counter(handshake_auth_failed, 1),
                    telemetry:execute([erl_bridge, handshake, failure],
                                      #{reason => auth_failed,
                                        peer => State#state.peer}),
                    {reject, erl_bridge_proto:encode_hello_ack(0, ?HELLO_AUTH_FAILED)}
            end
    end.

%% A peer presented a credential to a server that is not checking any. The
%% handshake is allowed -- every peer is already trusted -- but this is
%% almost always a deployment mistake on one side, so it earns a log line.
%% The token itself is never logged.
warn_if_token_ignored(undefined, <<>>, _State) ->
    ok;
warn_if_token_ignored(undefined, _Presented, #state{peer = Peer}) ->
    logger:warning("peer ~s presented an auth token but this server has none "
                   "configured -- the token was NOT verified", [Peer]);
warn_if_token_ignored(_Configured, _Presented, _State) ->
    ok.

on_request(Payload, State) ->
    case erl_bridge_proto:decode_request(Payload) of
        {error, _Reason} ->
            erl_bridge_metrics:counter(requests_malformed, 1),
            logger:warning("closing connection: malformed_request (peer ~s)",
                           [State#state.peer]),
            {stop, normal, State};
        {ok, #{opcode := Opcode}} when Opcode =/= ?OP_ADD ->
            erl_bridge_metrics:counter(requests_bad_opcode, 1),
            logger:warning("closing connection: bad_opcode (peer ~s)",
                           [State#state.peer]),
            {stop, normal, State};
        {ok, #{id := Id, a := A, b := B}} ->
            {ok, {Status, Result}} = erl_bridge_proto:add_result(A, B),
            count_request(Status),
            Reply = erl_bridge_proto:encode_response(Id, Status, Result),
            case send(State#state.socket, Reply) of
                ok ->
                    {noreply, await_request(State)};
                {error, Reason} ->
                    logger:warning("send failed: ~p (peer ~s)",
                                   [Reason, State#state.peer]),
                    {stop, normal, State}
            end
    end.

count_request(0) -> erl_bridge_metrics:counter(requests_ok, 1);
count_request(1) -> erl_bridge_metrics:counter(requests_overflow, 1).

%% The deadline passed with nothing received, so the connection is reaped.
%% Ordinary, not a failure: no warning, with the counters and telemetry
%% below as the record.
%%
%% This stops in both phases. The handshake deadline and the request
%% deadline are both "how long this connection may stay silent"; letting
%% an idle connection live forever would hold its slot and socket open
%% indefinitely.
on_idle(#state{phase = awaiting_hello, peer = Peer} = State) ->
    erl_bridge_metrics:counter(handshake_timeout, 1),
    telemetry:execute([erl_bridge, handshake, failure],
                      #{reason => timeout, peer => Peer}),
    {stop, normal, State};
on_idle(#state{peer = Peer} = State) ->
    telemetry:execute([erl_bridge, request, idle_timeout], #{peer => Peer}),
    {stop, normal, State}.

on_socket_error(Reason, #state{peer = Peer} = State) ->
    logger:warning("connection error: ~p (peer ~s)", [Reason, Peer]),
    {stop, normal, State}.

%% Arms the next request deadline and re-enters the loop.
await_request(#state{cfg = #cfg{request_timeout = Timeout}} = State) ->
    State#state{deadline = now_ms() + Timeout}.

%%%===================================================================
%%% Internal: deadline-aware receive
%%%===================================================================

%% @doc Wait for one frame, bounded by both the deadline and the poll
%% interval.
%%
%% Two distinct outcomes matter and must not be conflated:
%%
%% <ul>
%%   <li>`idle' -- the *deadline* passed. The peer has been silent for too
%%       long, so the connection is reaped.</li>
%%   <li>`{await, State}' -- this *poll slice* expired but the deadline has
%%       not. Keep waiting with the same deadline.</li>
%% </ul>
%%
%% Treating the slice timeout as the deadline would reap every connection
%% after a single poll interval -- a 30 s request timeout would silently
%% become 1 s. That distinction is the whole reason this is a named
%% function rather than an inline case in step/1.
-spec wait_for_frame(#state{}) ->
          {frame, binary()} | idle | gone
          | {socket_error, term()} | {await, #state{}}.
wait_for_frame(#state{socket = Socket, deadline = Deadline} = State) ->
    Remaining = Deadline - now_ms(),
    case Remaining =< 0 of
        true ->
            idle;
        false ->
            Wait = erlang:min(Remaining, ?POLL_INTERVAL),
            case erl_bridge_transport:recv(Socket, 0, Wait) of
                {ok, Frame} -> {frame, Frame};
                {error, timeout} -> {await, State};
                {error, closed} -> gone;
                {error, Reason} -> {socket_error, Reason}
            end
    end.

send(Socket, Data) ->
    erl_bridge_transport:send(Socket, Data).

is_tls({ssl, _}) -> true;
is_tls({gen_tcp, _}) -> false.

now_ms() ->
    erlang:monotonic_time(millisecond).
