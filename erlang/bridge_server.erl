%% @doc Length-prefixed TCP bridge server speaking protocol v1.
%%
%% Concurrency model: N acceptor processes, one worker per connection.
%% Each acceptor owns its own listening socket bound to the same port via
%% `SO_REUSEPORT`, so the kernel distributes incoming connections across
%% them. Acceptors never handle requests themselves -- they accept a
%% socket, transfer ownership to a freshly spawned worker, and loop.
%%
%% Each worker serves one connection strictly sequentially, which matches
%% the protocol's lockstep semantics. Sockets use passive mode
%% (`{active, false}`), so a slow client only ever blocks its own worker.
%% Every blocking call has an explicit timeout: 1000 ms for accept, 30 s
%% for receive.
%%
%% A shared `atomics` counter caps concurrent workers. When the cap is
%% reached, incoming connections are closed immediately rather than
%% queued.
%%
%% Because every socket sets `SO_REUSEPORT`, a second server instance on
%% the same port does NOT fail with `eaddrinuse`; it binds successfully
%% and the kernel splits connections between the instances. This is
%% deliberate and allows scaling across processes and hosts, but it also
%% means a duplicate launch is not reported as an error.
%%
%% This is a protocol example, not a production service. It has no
%% authentication, no TLS, no request deadlines, and no monitoring.
-module(bridge_server).
-export([start_link/1, start_link/2, start_link/3, acceptor_count/0,
         connection_limit/0, stop/1]).

-define(MAX_PACKET_SIZE, 1048576).
-define(MAX_ACCEPTORS, 8).
-define(MAX_CONNECTIONS, 128).

%% @equiv start_link(Port, undefined, undefined)
start_link(Port) ->
    start_link(Port, undefined, undefined).

%% @equiv start_link(Port, AcceptorCount, undefined)
start_link(Port, AcceptorCount) ->
    start_link(Port, AcceptorCount, undefined).

%% @doc Starts the server with an explicit acceptor count and connection cap.
%% Pass `undefined` for either argument to take the default.
%%
%% Returns `{ok, Pids}` where `Pids` is a list of acceptor processes, or
%% `{error, Reason}`. If any acceptor fails to bind, the ones that already
%% started are stopped, so no listener is left behind.
start_link(Port, AcceptorCount, MaxConnections)
  when is_integer(Port), Port > 0, Port < 65536 ->
    Count = acceptor_count(AcceptorCount),
    Limit = connection_limit(MaxConnections),
    Conns = atomics:new(1, [{signed, false}]),
    Parent = self(),
    Pids = [spawn_link(fun() -> acceptor(Parent, Port, Conns, Limit) end)
            || _ <- lists:seq(1, Count)],
    await_start(Pids, []);
start_link(_Port, _AcceptorCount, _MaxConnections) ->
    {error, badarg}.

%% @doc Returns the default acceptor count: the number of online
%% schedulers, capped at 8.
acceptor_count() ->
    min(erlang:system_info(schedulers_online), ?MAX_ACCEPTORS).

acceptor_count(undefined) ->
    acceptor_count();
acceptor_count(N) when is_integer(N), N > 0 ->
    min(N, ?MAX_ACCEPTORS);
acceptor_count(_Other) ->
    acceptor_count().

%% @doc Returns the default cap on concurrent worker processes (128).
connection_limit() ->
    ?MAX_CONNECTIONS.

connection_limit(undefined) ->
    connection_limit();
connection_limit(N) when is_integer(N), N > 0 ->
    N;
connection_limit(_Other) ->
    connection_limit().

%% Reserves one connection slot, or returns `full` when the cap is
%% already reached. Compare-and-exchange so concurrent acceptors cannot
%% both observe a free slot and overshoot the limit.
acquire_slot(Conns, Limit) ->
    case atomics:get(Conns, 1) of
        N when N < Limit ->
            case atomics:compare_exchange(Conns, 1, N, N + 1) of
                ok -> acquired;
                _ -> acquire_slot(Conns, Limit)
            end;
        _AlreadyAtLimit ->
            full
    end.

%% Waits for every acceptor to report. If any fails to bind, the ones
%% that already succeeded are torn down so no listener is left behind.
await_start([], Started) ->
    {ok, Started};
await_start(Pids, Started) ->
    receive
        {Pid, started} ->
            await_start(Pids -- [Pid], [Pid | Started]);
        {Pid, {error, Reason}} ->
            [P ! stop || P <- Started],
            exit(Pid, kill),
            {error, Reason}
    after 5000 ->
        [P ! stop || P <- Pids],
        {error, acceptor_start_timeout}
    end.

%% @doc Stops the server. Accepts the list returned by `start_link/1,2,3`,
%% or a single acceptor pid. Each acceptor stops within 1000 ms of being
%% signalled, since it only checks for `stop` between accepts.
stop(Pids) when is_list(Pids) ->
    [P ! stop || P <- Pids],
    ok;
stop(Pid) when is_pid(Pid) ->
    Pid ! stop,
    ok.

%% @private
%% One acceptor. `{reuseport, true}` lets every acceptor -- and any other
%% server instance on this host -- bind the same port; the kernel then
%% distributes connections between them.
acceptor(Parent, Port, Conns, Limit) ->
    case gen_tcp:listen(Port, [
        binary,
        {packet, 4},
        {packet_size, ?MAX_PACKET_SIZE},
        {active, false},
        {reuseaddr, true},
        {reuseport, true},
        {backlog, 128}
    ]) of
        {ok, ListenSocket} ->
            Parent ! {self(), started},
            accept_loop(ListenSocket, Conns, Limit);
        {error, Reason} ->
            Parent ! {self(), {error, Reason}}
    end.

accept_loop(ListenSocket, Conns, Limit) ->
    receive
        stop ->
            gen_tcp:close(ListenSocket),
            ok
    after 0 ->
        case gen_tcp:accept(ListenSocket, 1000) of
            {ok, Socket} ->
                case acquire_slot(Conns, Limit) of
                    acquired ->
                        Worker = spawn(fun() ->
                            receive
                                {serve, ClientSocket} ->
                                    serve(ClientSocket, Conns)
                            after 5000 ->
                                %% Socket never arrived; reclaim the slot.
                                atomics:sub(Conns, 1, 1)
                            end
                        end),
                        case gen_tcp:controlling_process(Socket, Worker) of
                            ok ->
                                Worker ! {serve, Socket};
                            {error, _} ->
                                %% `exit(Pid, kill)` is untrappable, so the
                                %% worker's `after` will not run. Release here.
                                atomics:sub(Conns, 1, 1),
                                exit(Worker, kill),
                                gen_tcp:close(Socket)
                        end;
                    full ->
                        gen_tcp:close(Socket)
                end,
                accept_loop(ListenSocket, Conns, Limit);
            {error, timeout} ->
                accept_loop(ListenSocket, Conns, Limit);
            {error, closed} ->
                ok;
            {error, Reason} ->
                io:format("accept error: ~p~n", [Reason]),
                accept_loop(ListenSocket, Conns, Limit)
        end
    end.

serve(Socket, Conns) ->
    try serve_loop(Socket)
    after
        gen_tcp:close(Socket),
        atomics:sub(Conns, 1, 1)
    end.

serve_loop(Socket) ->
    case gen_tcp:recv(Socket, 0, 30000) of
        {ok, <<RequestId:32/unsigned-big, 1:8,
               A:64/signed-big, B:64/signed-big>>} ->
            Sum = A + B,
            case fits_int64(Sum) of
                true ->
                    send_reply(Socket, RequestId, 0, Sum);
                false ->
                    send_reply(Socket, RequestId, 1, 0)
            end;
        {ok, _MalformedPacket} ->
            {error, malformed_packet};
        {error, timeout} ->
            ok;
        {error, closed} ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

send_reply(Socket, RequestId, Status, Result) ->
    Reply = <<RequestId:32/unsigned-big,
              Status:8,
              Result:64/signed-big>>,
    case gen_tcp:send(Socket, Reply) of
        ok ->
            serve_loop(Socket);
        {error, Reason} ->
            {error, Reason}
    end.

fits_int64(N) ->
    N >= -9223372036854775808 andalso
    N =< 9223372036854775807.