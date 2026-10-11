%% EUnit tests for bridge_server.
%%
%% Run with:  bun run test
%%
%% These cover the wire-level behaviour documented in PROTOCOL.md and the
%% concurrency guarantees documented in README.md, including the
%% SO_REUSEPORT multi-instance behaviour.
-module(bridge_server_tests).

-include_lib("eunit/include/eunit.hrl").

%% Each test uses its own port so they can never collide, even if run
%% in parallel or against an already-running server elsewhere.
-define(PORT_ADD, 45101).
-define(PORT_OVERFLOW, 45102).
-define(PORT_MALFORMED, 45103).
-define(PORT_CAP, 45104).
-define(PORT_MULTI, 45105).
-define(PORT_API, 45106).

%%% ------------------------------------------------------------------
%%% Helpers
%%% ------------------------------------------------------------------

%% start_link/3 links the acceptors to us. Without trap_exit a normal
%% test exit would leave them running, leaking the port.
start_server(Port, Acceptors, Limit) ->
    process_flag(trap_exit, true),
    {ok, Pids} = bridge_server:start_link(Port, Acceptors, Limit),
    Pids.

stop_server(Pids) ->
    bridge_server:stop(Pids),
    %% Acceptors only observe `stop` between accepts, so allow up to one
    %% accept timeout before the port is actually released.
    timer:sleep(1200),
    ok.

%% Runs Fun with a fresh server, always stopping it afterwards.
with_server(Port, Acceptors, Limit, Fun) ->
    Pids = start_server(Port, Acceptors, Limit),
    try
        Fun()
    after
        stop_server(Pids)
    end.

%% add(Port, Id, A, B) -> {ok, Id, Result} | {error_status, 1} | {recv_error, R}
add(Port, Id, A, B) ->
    request(Port, <<Id:32/unsigned-big, 1:8, A:64/signed-big, B:64/signed-big>>).

%% `binary` matters: without it recv/2 returns a list, not a binary, and
%% the response patterns below would never match. The socket is raw, so
%% the 4-byte length prefix is still present in what recv/2 returns and
%% is skipped before matching on the payload.
request(Port, Payload) ->
    case gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}], 2000) of
        {error, Reason} ->
            {connect_error, Reason};
        {ok, S} ->
            try
                ok = gen_tcp:send(S, <<(byte_size(Payload)):32/unsigned-big,
                                       Payload/binary>>),
                case gen_tcp:recv(S, 0, 2000) of
                    {ok, <<_:32, Id:32/unsigned-big, 0:8,
                           Result:64/signed-big>>} ->
                        {ok, Id, Result};
                    {ok, <<_:32, _Id:32/unsigned-big, 1:8, _/binary>>} ->
                        {error_status, 1};
                    {error, Reason} ->
                        {recv_error, Reason}
                end
            after
                gen_tcp:close(S)
            end
    end.

%%% ------------------------------------------------------------------
%%% Protocol v1: arithmetic
%%% ------------------------------------------------------------------

addition_test() ->
    with_server(?PORT_ADD, 2, 16, fun() ->
        ?assertEqual({ok, 1, 30}, add(?PORT_ADD, 1, 10, 20)),
        ?assertEqual({ok, 2, 5}, add(?PORT_ADD, 2, -2, 7)),
        ?assertEqual({ok, 3, 0}, add(?PORT_ADD, 3, 0, 0)),
        %% Values beyond 32-bit range must survive the round trip.
        ?assertEqual({ok, 4, 9000000001}, add(?PORT_ADD, 4, 9000000000, 1)),
        %% The request ID is echoed back verbatim.
        ?assertEqual({ok, 5, 7}, add(?PORT_ADD, 5, 3, 4)),
        ?assertEqual({ok, 4294967295, 7}, add(?PORT_ADD, 4294967295, 3, 4))
    end).

%% 64-bit boundaries: the extremes themselves are representable, so these
%% must succeed rather than trip the overflow guard.
boundary_values_test() ->
    with_server(?PORT_OVERFLOW, 2, 16, fun() ->
        ?assertEqual({ok, 1, 9223372036854775807},
                     add(?PORT_OVERFLOW, 1, 9223372036854775806, 1)),
        ?assertEqual({ok, 2, -9223372036854775807},
                     add(?PORT_OVERFLOW, 2, -9223372036854775808, 1)),
        %% Erlang has bignums, so these would wrap silently without fits_int64/1.
        ?assertEqual({error_status, 1},
                     add(?PORT_OVERFLOW, 3, 9223372036854775807, 1)),
        ?assertEqual({error_status, 1},
                     add(?PORT_OVERFLOW, 4, -9223372036854775808, -1)),
        ?assertEqual({error_status, 1},
                     add(?PORT_OVERFLOW, 5, 9223372036854775807,
                         9223372036854775807))
    end).

%%% ------------------------------------------------------------------
%%% Protocol v1: malformed input closes the connection
%%% ------------------------------------------------------------------

malformed_test() ->
    with_server(?PORT_MALFORMED, 2, 16, fun() ->
        %% Unknown opcode.
        ?assertMatch({recv_error, _},
                     request(?PORT_MALFORMED,
                             <<1:32/unsigned-big, 7:8, 1:64/signed-big,
                               2:64/signed-big>>)),
        %% Opcode 0 is not defined either.
        ?assertMatch({recv_error, _},
                     request(?PORT_MALFORMED,
                             <<1:32/unsigned-big, 0:8, 1:64/signed-big,
                               2:64/signed-big>>)),
        %% Declared length shorter than a valid request.
        ?assertMatch({recv_error, _},
                     request(?PORT_MALFORMED, <<0:32/unsigned-big, 1:8, 1:8>>)),
        %% Declared length longer than a valid request.
        ?assertMatch({recv_error, _},
                     request(?PORT_MALFORMED,
                             <<64:32/unsigned-big, 1:32/unsigned-big, 1:8,
                               0:128>>)),
        %% The server survives malformed input and keeps serving.
        ?assertEqual({ok, 1, 30}, add(?PORT_MALFORMED, 1, 10, 20))
    end).

%%% ------------------------------------------------------------------
%%% Concurrency: connection cap
%%% ------------------------------------------------------------------

%% The cap is a hard limit, and slots are reclaimed when workers exit.
%% The reclaim assertion guards the leak that would occur if the slot
%% were only released in serve/1's `after` block: on the
%% controlling_process failure path the worker is killed untrappably, so
%% that path has to release the slot explicitly.
connection_cap_test() ->
    with_server(?PORT_CAP, 3, 8, fun() ->
        Sockets = hold_open(?PORT_CAP, 8),
        try
            %% The connection past the cap is closed without a reply.
            ?assertMatch({recv_error, closed}, add(?PORT_CAP, 1, 1, 2)),
            [gen_tcp:close(S) || S <- Sockets],
            %% Slots are reclaimed, so the server serves again.
            ?assertEqual({ok, 1, 3}, add(?PORT_CAP, 1, 1, 2))
        after
            [gen_tcp:close(S) || S <- Sockets]
        end
    end).

%% Opens N connections, leaves them open, and lets the acceptors drain
%% the backlog so the cap assertion cannot race.
hold_open(Port, N) ->
    Sockets = [begin
                   {ok, S} = gen_tcp:connect("127.0.0.1", Port,
                                            [binary, {active, false}], 2000),
                   S
               end || _ <- lists:seq(1, N)],
    timer:sleep(500),
    Sockets.

%%% ------------------------------------------------------------------
%%% Concurrency: SO_REUSEPORT lets several instances share a port
%%% ------------------------------------------------------------------

%% Locks in the behaviour change from v0.2.0. Because every listening
%% socket sets SO_REUSEPORT, a second instance on the same port binds
%% successfully rather than failing with eaddrinuse, and the kernel
%% splits connections between them. If someone removes {reuseport, true}
%% this test fails, which is the signal to update the README.
multiple_instances_share_port_test() ->
    process_flag(trap_exit, true),
    First = start_server(?PORT_MULTI, 2, 16),
    try
        {ok, Second} = bridge_server:start_link(?PORT_MULTI, 2, 16),
        try
            ?assertEqual(2, length(First)),
            ?assertEqual(2, length(Second)),
            %% Traffic against the shared port is still served correctly.
            ?assertEqual({ok, 1, 30}, add(?PORT_MULTI, 1, 10, 20))
        after
            bridge_server:stop(Second)
        end
    after
        bridge_server:stop(First)
    end.

%%% ------------------------------------------------------------------
%%% API surface
%%% ------------------------------------------------------------------

api_test() ->
    process_flag(trap_exit, true),
    %% start_link/3 returns a list of live, distinct acceptor pids.
    {ok, Pids1} = bridge_server:start_link(?PORT_API, 2, 8),
    try
        ?assert(is_list(Pids1)),
        ?assertEqual(2, length(Pids1)),
        ?assert(lists:all(fun is_process_alive/1, Pids1)),
        ?assertEqual(2, length(lists:usort(Pids1)))
    after
        bridge_server:stop(Pids1)
    end,
    timer:sleep(1200),

    %% stop/1 also accepts a bare pid.
    {ok, [Single]} = bridge_server:start_link(?PORT_API, 1, 8),
    ?assertEqual(ok, bridge_server:stop(Single)),
    timer:sleep(1200),
    ?assertNot(is_process_alive(Single)),

    %% Stopping releases the port.
    ?assertMatch({error, econnrefused},
                 gen_tcp:connect("127.0.0.1", ?PORT_API,
                                 [binary, {active, false}], 500)),
    ok.

defaults_test() ->
    ?assert(bridge_server:acceptor_count() >= 1),
    ?assert(bridge_server:acceptor_count() =< 8),
    ?assertEqual(128, bridge_server:connection_limit()).

invalid_port_test() ->
    ?assertEqual({error, badarg}, bridge_server:start_link(0, 2, 8)),
    ?assertEqual({error, badarg}, bridge_server:start_link(70000, 2, 8)),
    ?assertEqual({error, badarg}, bridge_server:start_link(-1, 2, 8)),
    ?assertEqual({error, badarg}, bridge_server:start_link(a, 2, 8)).