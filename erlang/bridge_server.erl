-module(bridge_server).
-export([start_link/1, stop/1]).

-define(MAX_PACKET_SIZE, 1048576).

start_link(Port) when is_integer(Port), Port > 0, Port < 65536 ->
    Parent = self(),
    Pid = spawn_link(fun() -> listen(Parent, Port) end),
    receive
        {Pid, started} -> {ok, Pid};
        {Pid, {error, Reason}} -> {error, Reason}
    after 5000 ->
        {error, listen_start_timeout}
    end.

stop(Pid) when is_pid(Pid) ->
    Pid ! stop,
    ok.

listen(Parent, Port) ->
    case gen_tcp:listen(Port, [
        binary,
        {packet, 4},
        {packet_size, ?MAX_PACKET_SIZE},
        {active, false},
        {reuseaddr, true},
        {backlog, 128}
    ]) of
        {ok, ListenSocket} ->
            Parent ! {self(), started},
            accept_loop(ListenSocket);
        {error, Reason} ->
            Parent ! {self(), {error, Reason}}
    end.

accept_loop(ListenSocket) ->
    receive
        stop ->
            gen_tcp:close(ListenSocket),
            ok
    after 0 ->
        case gen_tcp:accept(ListenSocket, 1000) of
            {ok, Socket} ->
                Worker = spawn(fun() ->
                    receive
                        {serve, ClientSocket} ->
                            serve(ClientSocket)
                    end
                end),
                case gen_tcp:controlling_process(Socket, Worker) of
                    ok ->
                        Worker ! {serve, Socket};
                    {error, _} ->
                        exit(Worker, kill),
                        gen_tcp:close(Socket)
                end,
                accept_loop(ListenSocket);
            {error, timeout} ->
                accept_loop(ListenSocket);
            {error, closed} ->
                ok;
            {error, Reason} ->
                io:format("accept error: ~p~n", [Reason]),
                accept_loop(ListenSocket)
        end
    end.

serve(Socket) ->
    try serve_loop(Socket)
    after
        gen_tcp:close(Socket)
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
