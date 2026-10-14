%%%-------------------------------------------------------------------
%%% @doc Integration tests: the real OTP application, a real TCP
%%% listener, a real client socket.
%%%
%%% The server is a singleton (it registers `erl_bridge_sup' and friends),
%%% so each test starts the application with an explicit port and stops it
%%% afterwards. Ports are distinct per test and, where possible, bound to
%%% port 0 so the OS assigns a free one -- that removes the class of
%%% failure where a previous run left a port in TIME_WAIT.
%%%
%%% TLS tests generate a throwaway self-signed certificate. If `openssl'
%%% is not on PATH the TLS tests are skipped rather than failed: a missing
%%% build tool is not a defect in the server.
%%% @end
%%%-------------------------------------------------------------------
-module(erl_bridge_server_tests).

-include_lib("eunit/include/eunit.hrl").

-include("erl_bridge.hrl").

-define(V2, ?PROTO_VERSION_MAX).

%%%===================================================================
%%% Harness
%%%===================================================================

%% Runs Fun with the server started, always stopping it afterwards.
%%
%% The server is a singleton, and application:ensure_all_started/1 answers
%% `ok' for an application that is *already* running -- so if a previous
%% test left it up, start/1 would silently keep that test's port and token
%% and this one would be asserting against another test's configuration.
%% Hence the explicit wait for a stopped server first.
with_server(Overrides, Fun) ->
    ok = ensure_stopped(),
    ok = bridge_server:start(Overrides),
    try
        timer:sleep(100),
        Fun(bridge_server:info())
    after
        ok = stop_server(),
        timer:sleep(200)
    end.

%% Stops the server without blocking the test process.
%%
%% application:stop/1 is synchronous and an acceptor needs up to one
%% accept timeout to notice the shutdown, so calling it inline can push a
%% test past eunit's 5 s default -- which surfaces as a mysterious "timed
%% out" in the *next* test's teardown rather than as a shutdown problem.
%% Stopping in a spawned process and polling keeps the wait bounded and
%% the failure where it belongs.
stop_server() ->
    spawn(fun() -> _ = bridge_server:stop() end),
    wait_until(fun() -> not bridge_server:running() end, 40).

ensure_stopped() ->
    _ = bridge_server:stop(),
    case wait_until(fun() -> not bridge_server:running() end, 60) of
        ok ->
            ok;
        timeout ->
            %% A stuck supervisor would otherwise poison every later test,
            %% so fail here rather than letting it surface as a mysterious
            %% assertion ten tests on.
            erlang:error({server_would_not_stop, bridge_server:info()})
    end.

wait_until(_Predicate, 0) ->
    timeout;
wait_until(Predicate, Retries) ->
    case Predicate() of
        true -> ok;
        false ->
            timer:sleep(100),
            wait_until(Predicate, Retries - 1)
    end.

%% A port of 0 asks the OS for a free port; the server then reports which
%% one it got, so tests cannot collide with each other or with a previous
%% run.
%%
%% accept_timeout is short because it also bounds how long a shutdown
%% takes: an acceptor can only notice the stop between accepts. 200 ms
%% keeps teardown quick without affecting anything the tests measure.
free_port_config() ->
    #{port => 0, reuseport => false, acceptor_count => 1, accept_timeout => 200}.

bound_port() ->
    {ok, Cfg} = application:get_env(?APP, resolved_config),
    Cfg#cfg.port.

%%%===================================================================
%%% Client helpers
%%%===================================================================

connect(Port) ->
    gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, 4}],
                   2000).

%% Sends a HELLO and returns {ok, Ack} | {closed} | {error, R}.
hello(Socket, Version, Token) ->
    send(Socket,
         <<Version:8, (byte_size(Token)):16/unsigned-big, Token/binary>>),
    case recv(Socket, 0, 2000) of
        {ok, Ack} -> {ok, Ack};
        {error, R} -> {error, R}
    end.

%% Dispatch on socket type. An ssl socket is the tuple {sslsocket, ...};
%% gen_tcp calls on one raise function_clause, which is a confusing way to
%% discover that TLS is enabled.
send(Socket, Data) ->
    case is_ssl(Socket) of
        true -> ssl:send(Socket, Data);
        false -> gen_tcp:send(Socket, Data)
    end.

recv(Socket, Length, Timeout) ->
    case is_ssl(Socket) of
        true -> ssl:recv(Socket, Length, Timeout);
        false -> gen_tcp:recv(Socket, Length, Timeout)
    end.

close(Socket) ->
    case is_ssl(Socket) of
        true -> ssl:close(Socket);
        false -> gen_tcp:close(Socket)
    end.

is_ssl(Socket) when is_tuple(Socket), tuple_size(Socket) > 0 ->
    element(1, Socket) =:= sslsocket;
is_ssl(_Other) ->
    false.

%% A client that has completed the handshake.
connected_client(Port, Token) ->
    {ok, S} = connect(Port),
    {ok, <<?V2:8, ?HELLO_OK:8>>} = hello(S, ?V2, Token),
    S.

close_quietly(Socket) ->
    _ = close(Socket),
    ok.

add(Socket, Id, A, B) ->
    ok = send(Socket,
              <<Id:32/unsigned-big, ?OP_ADD:8,
                A:64/signed-big, B:64/signed-big>>),
    recv(Socket, 0, 2000).

%%%===================================================================
%%% Handshake
%%%===================================================================

%% A request before the handshake must not be served. This is the property
%% that makes "v1 is no longer accepted" enforceable.
request_before_handshake_is_refused_test() ->
    with_server(free_port_config(), fun(_Info) ->
        Port = bound_port(),
        {ok, S} = connect(Port),
        %% Send a valid add request with no HELLO first.
        ok = gen_tcp:send(S, <<1:32/unsigned-big, ?OP_ADD:8,
                              10:64/signed-big, 20:64/signed-big>>),
        ?assertMatch({error, closed}, gen_tcp:recv(S, 0, 2000)),
        gen_tcp:close(S)
    end).

%% The handshake deadline is shorter than the request timeout, so a peer
%% that connects and says nothing releases its slot quickly.
%%
%% The deadline is shortened in the config and the eunit timeout raised:
%% the default 5s test timeout is shorter than a default 5s handshake
%% timeout, so the test would be cancelled before it could observe the
%% behaviour it exists to check.
handshake_timeout_test_() ->
    {timeout, 30,
     fun() ->
        with_server(maps:merge(free_port_config(),
                               #{handshake_timeout => 400}),
                    fun(_Info) ->
                        {ok, S} = connect(bound_port()),
                        %% Sends nothing; the server must give up on its own.
                        ?assertMatch({error, closed}, gen_tcp:recv(S, 0, 3000)),
                        close_quietly(S)
                    end)
     end}.

%%%===================================================================
%%% Version negotiation
%%%===================================================================

%% v1 was unauthenticated, so accepting it would be an auth bypass.
version_1_is_rejected_test() ->
    with_server(free_port_config(), fun(_Info) ->
        {ok, S} = connect(bound_port()),
        ?assertEqual({ok, <<0:8, ?HELLO_BAD_VERSION:8>>}, hello(S, 1, <<>>)),
        gen_tcp:close(S)
    end).

unknown_version_is_rejected_test() ->
    with_server(free_port_config(), fun(_Info) ->
        {ok, S} = connect(bound_port()),
        ?assertEqual({ok, <<0:8, ?HELLO_BAD_VERSION:8>>}, hello(S, 99, <<>>)),
        gen_tcp:close(S)
    end).

%%%===================================================================
%%% Authentication
%%%===================================================================

%% With no token configured the handshake still succeeds with an empty
%% token: auth is off, which is a documented and logged choice.
no_token_configured_accepts_test() ->
    with_server(free_port_config(), fun(_Info) ->
        {ok, S} = connect(bound_port()),
        ?assertEqual({ok, <<?V2:8, ?HELLO_OK:8>>}, hello(S, ?V2, <<>>)),
        gen_tcp:close(S)
    end).

correct_token_accepted_test() ->
    with_server(maps:merge(free_port_config(), #{token => <<"correct-horse">>}),
                fun(_Info) ->
        {ok, S} = connect(bound_port()),
        ?assertEqual(({ok, <<?V2:8, ?HELLO_OK:8>>}),
                     hello(S, ?V2, <<"correct-horse">>)),
        gen_tcp:close(S)
    end).

wrong_token_rejected_test() ->
    with_server(maps:merge(free_port_config(), #{token => <<"correct-horse">>}),
                fun(_Info) ->
        {ok, S} = connect(bound_port()),
        ?assertEqual(({ok, <<0:8, ?HELLO_AUTH_FAILED:8>>}),
                     hello(S, ?V2, <<"battery-staple">>)),
        gen_tcp:close(S)
    end).

missing_token_rejected_test() ->
    with_server(maps:merge(free_port_config(), #{token => <<"correct-horse">>}),
                fun(_Info) ->
        {ok, S} = connect(bound_port()),
        ?assertEqual({ok, <<0:8, ?HELLO_AUTH_FAILED:8>>}, hello(S, ?V2, <<>>)),
        gen_tcp:close(S)
    end).

%% A rejected connection must not serve anything afterwards.
rejected_connection_serves_nothing_test() ->
    with_server(maps:merge(free_port_config(), #{token => <<"s3cret">>}),
                fun(_Info) ->
        {ok, S} = connect(bound_port()),
        {ok, <<0:8, ?HELLO_AUTH_FAILED:8>>} = hello(S, ?V2, <<"wrong">>),
        ?assertMatch({error, _}, add(S, 1, 10, 20)),
        gen_tcp:close(S)
    end).

%%%===================================================================
%%% Requests
%%%===================================================================

arithmetic_test() ->
    with_server(free_port_config(), fun(_Info) ->
        S = connected_client(bound_port(), <<>>),
        ?assertMatch({ok, <<1:32/unsigned-big, 0:8, 30:64/signed-big>>},
                     add(S, 1, 10, 20)),
        ?assertMatch({ok, <<2:32/unsigned-big, 0:8, 5:64/signed-big>>},
                     add(S, 2, -2, 7)),
        %% Beyond 32 bits, and the extremes themselves.
        ?assertMatch({ok, <<3:32/unsigned-big, 0:8, 9000000001:64/signed-big>>},
                     add(S, 3, 9000000000, 1)),
        ?assertMatch({ok, <<4:32/unsigned-big, 0:8,
                            9223372036854775807:64/signed-big>>},
                     add(S, 4, 9223372036854775806, 1)),
        %% Overflow reports status=1 rather than wrapping.
        ?assertMatch({ok, <<5:32/unsigned-big, 1:8, 0:64/signed-big>>},
                     add(S, 5, 9223372036854775807, 1)),
        %% The request id is echoed verbatim, including max u32.
        ?assertMatch({ok, <<4294967295:32/unsigned-big, 0:8, 7:64/signed-big>>},
                     add(S, 4294967295, 3, 4)),
        gen_tcp:close(S)
    end).

bad_opcode_closes_test() ->
    with_server(free_port_config(), fun(_Info) ->
        S = connected_client(bound_port(), <<>>),
        ok = gen_tcp:send(S, <<1:32/unsigned-big, 7:8,
                              1:64/signed-big, 2:64/signed-big>>),
        ?assertMatch({error, closed}, gen_tcp:recv(S, 0, 2000)),
        gen_tcp:close(S)
    end).

malformed_payload_closes_test() ->
    with_server(free_port_config(), fun(_Info) ->
        S = connected_client(bound_port(), <<>>),
        ok = gen_tcp:send(S, <<1:8, 2:8>>),
        ?assertMatch({error, closed}, gen_tcp:recv(S, 0, 2000)),
        gen_tcp:close(S)
    end).

%% A connection that is closed mid-stream must not take the server with
%% it. This is the crash-safety check for the worker lifecycle.
server_survives_abuse_test() ->
    with_server(free_port_config(), fun(_Info) ->
        Port = bound_port(),
        lists:foreach(
          fun(_) ->
                  {ok, S} = connect(Port),
                  gen_tcp:send(S, <<1:32/unsigned-big, 99:8,
                                    1:64/signed-big, 2:64/signed-big>>),
                  timer:sleep(10),
                  gen_tcp:close(S)
          end, lists:seq(1, 20)),
        %% Still serving.
        S = connected_client(Port, <<>>),
        ?assertMatch({ok, <<1:32/unsigned-big, 0:8, 30:64/signed-big>>},
                     add(S, 1, 10, 20)),
        gen_tcp:close(S)
    end).

%%%===================================================================
%%% Connection cap
%%%===================================================================

%% The cap is global, not per acceptor, and slots are reclaimed when
%% workers exit -- otherwise the server would wedge after `limit'
%% connections.
connection_cap_test() ->
    with_server(maps:merge(free_port_config(),
                           #{max_connections => 2, acceptor_count => 4}),
                fun(_Info) ->
        Port = bound_port(),
        Sockets = [begin
                       {ok, S} = connect(Port),
                       {ok, <<?V2:8, ?HELLO_OK:8>>} = hello(S, ?V2, <<>>),
                       S
                   end || _ <- lists:seq(1, 2)],
        try
            %% Third is over the cap: closed without an ACK.
            {ok, S3} = connect(Port),
            ?assertMatch({error, _}, hello(S3, ?V2, <<>>)),
            gen_tcp:close(S3),

            %% Close one; the slot must come back.
            gen_tcp:close(hd(Sockets)),
            %% Wait for the server to *observe* the close rather than
            %% sleeping a guessed interval: a connection worker only
            %% notices a peer has gone at its next poll, so a fixed sleep
            %% is either flaky or needlessly slow.
            ok = wait_until(fun() ->
                                    erl_bridge_acceptor_sup:connection_count()
                                        < 2
                            end, 50),
            S4 = connected_client(Port, <<>>),
            ?assertMatch({ok, <<1:32/unsigned-big, 0:8, 30:64/signed-big>>},
                         add(S4, 1, 10, 20)),
            gen_tcp:close(S4)
        after
            lists:foreach(fun(S) -> close_quietly(S) end, Sockets)
        end
    end).

%%%===================================================================
%%% Metrics
%%%===================================================================

metrics_recorded_test() ->
    with_server(free_port_config(), fun(_Info) ->
        Port = bound_port(),
        S = connected_client(Port, <<>>),
        {ok, _} = add(S, 1, 10, 20),
        {ok, _} = add(S, 2, 9223372036854775807, 1),
        close_quietly(S),
        timer:sleep(300),
        Metrics = maps:get(metrics, bridge_server:info()),
        ?assertEqual(1, metric(requests_ok, Metrics)),
        ?assertEqual(1, metric(requests_overflow, Metrics)),
        ?assert(metric(handshake_ok, Metrics) >= 1)
    end).

%% erl_bridge_metrics:describe/0 returns {Name, Value, Type} triples.
%% proplists:get_value/2 only matches 2-tuples, so it returns undefined
%% rather than failing -- hence this explicit lookup.
metric(Name, Metrics) ->
    case lists:keyfind(Name, 1, Metrics) of
        {Name, Value, _Type} -> Value;
        false -> undefined
    end.

%% The scrape endpoint must be reachable and serve valid Prometheus text.
metrics_endpoint_test() ->
    with_server(maps:merge(free_port_config(), #{metrics_port => 0}),
                fun(_Info) ->
        MetricsPort = erl_bridge_metrics_http:port(),
        {ok, S} = gen_tcp:connect("127.0.0.1", MetricsPort,
                                  [binary, {active, false}], 2000),
        ok = gen_tcp:send(S, <<"GET /metrics HTTP/1.1\r\nHost: x\r\n\r\n">>),
        {ok, Response} = gen_tcp:recv(S, 0, 2000),
        gen_tcp:close(S),
        Text = binary_to_list(Response),
        ?assertNotEqual(nomatch, string:find(Text, "200 OK")),
        ?assertNotEqual(nomatch, string:find(Text, "erl_bridge_requests_ok_total")),
        ?assertNotEqual(nomatch, string:find(Text, "# TYPE erl_bridge_connections_active gauge"))
    end).

metrics_endpoint_404_test() ->
    with_server(maps:merge(free_port_config(), #{metrics_port => 0}),
                fun(_Info) ->
        MetricsPort = erl_bridge_metrics_http:port(),
        {ok, S} = gen_tcp:connect("127.0.0.1", MetricsPort,
                                  [binary, {active, false}], 2000),
        ok = gen_tcp:send(S, <<"GET /nope HTTP/1.1\r\n\r\n">>),
        {ok, Response} = gen_tcp:recv(S, 0, 2000),
        gen_tcp:close(S),
        ?assertNotEqual(nomatch,
                        string:find(binary_to_list(Response), "404 Not Found"))
    end).

%%%===================================================================
%%% Supervision
%%%===================================================================

%% A second bind on an occupied port must fail loudly rather than being
%% silently absorbed. This is what `reuseport => false' buys you.
%%
%% This exercises the bind itself rather than starting a second server:
%% the server is a singleton OTP application, so "launch it twice" inside
%% one VM is a different and uninteresting question. The real duplicate
%% launch is a second OS process, which reduces to "can we bind the port?".
duplicate_bind_fails_test() ->
    with_server(#{port => 0, reuseport => false, acceptor_count => 1},
                fun(_Info) ->
        {ok, Cfg} = application:get_env(?APP, resolved_config),
        Busy = Cfg#cfg{port = bound_port(), reuseport = false},
        ?assertMatch({error, eaddrinuse},
                     erl_bridge_transport:listen(Busy#cfg.port, Busy))
    end).

%% With reuseport on -- the default -- a second bind on the same port
%% succeeds instead, and the kernel splits the traffic between instances.
%% Locking this in means removing {reuseport, true} fails the suite.
reuseport_allows_second_bind_test() ->
    with_server(#{port => 0, reuseport => true, acceptor_count => 1},
                fun(_Info) ->
        {ok, Cfg} = application:get_env(?APP, resolved_config),
        Shared = Cfg#cfg{port = bound_port(), reuseport = true},
        ?assertMatch({ok, {gen_tcp, _}},
                     erl_bridge_transport:listen(Shared#cfg.port, Shared))
    end).

%% Restarting after a stop must work: the singleton names have to be
%% released cleanly.
stop_then_restart_test() ->
    with_server(#{port => 0, reuseport => false, acceptor_count => 1},
                fun(_Info) ->
        ok = bridge_server:stop(),
        ?assertEqual(ok, wait_until(fun() -> not bridge_server:running() end, 50)),
        ?assertEqual(ok, bridge_server:start(#{port => 0,
                                               reuseport => false,
                                               acceptor_count => 1})),
        timer:sleep(100),
        %% The restarted server actually serves.
        S = connected_client(bound_port(), <<>>),
        ?assertMatch({ok, <<1:32/unsigned-big, 0:8, 30:64/signed-big>>},
                     add(S, 1, 10, 20)),
        close_quietly(S)
    end).

info_reports_config_test() ->
    with_server(maps:merge(free_port_config(), #{token => <<"s3cret">>}),
                fun(Info) ->
        ?assertEqual(true, maps:get(running, Info)),
        Cfg = maps:get(config, Info),
        ?assertEqual(<<"s3cret">>, Cfg#cfg.token),
        %% The secret must not appear in the logged description.
        ?assertEqual(nomatch,
                     string:find(erl_bridge_config:describe(Cfg), "s3cret"))
    end).

%%%===================================================================
%%% TLS
%%%===================================================================

%% TLS is optional, so this exercises the whole listener over an encrypted
%% connection -- including the case that matters most: a plaintext client
%% must NOT be able to talk to a TLS listener. Without that assertion,
%% enabling TLS could appear to work while offering no confidentiality.
%%
%% A throwaway self-signed certificate is generated with `openssl'. If
%% openssl is not on PATH the tests are skipped rather than failed: a
%% missing build tool is not a defect in the server.
tls_test_() ->
    {timeout, 90,
     fun() ->
        case make_cert() of
            {ok, Dir, Cert, Key} ->
                try
                    run_tls_tests(Cert, Key)
                after
                    remove_dir(Dir)
                end;
            skip ->
                ?debugMsg("openssl unavailable; skipping TLS tests")
        end
     end}.

run_tls_tests(Cert, Key) ->
    TLS = #{tls => #{certfile => Cert, keyfile => Key}},
    with_server(maps:merge(free_port_config(), TLS),
                fun(_Info) ->
        S = tls_client(bound_port(), <<"">>),
        ?assertMatch({ok, <<1:32/unsigned-big, 0:8, 30:64/signed-big>>},
                     add(S, 1, 10, 20)),
        close_quietly(S)
    end),

    %% A plaintext client must not be able to complete the protocol
    %% handshake with a TLS listener. Note that the TCP connect itself
    %% still succeeds -- TLS sits above it -- so the assertion is on the
    %% HELLO exchange, not on connect/2. Without this, enabling TLS could
    %% appear to work while offering no confidentiality at all.
    with_server(maps:merge(free_port_config(), TLS),
                fun(_Info) ->
        {ok, Plain} = connect(bound_port()),
        ?assertNotEqual({ok, <<?V2:8, ?HELLO_OK:8>>},
                        hello(Plain, ?V2, <<>>)),
        close_quietly(Plain)
    end),

    %% TLS with authentication on top.
    with_server(maps:merge(maps:merge(free_port_config(), TLS),
                           #{token => <<"tls-secret">>}),
                fun(_Info) ->
        S = tls_client(bound_port(), <<"tls-secret">>),
        ?assertMatch({ok, <<1:32/unsigned-big, 0:8, 7:64/signed-big>>},
                     add(S, 1, 3, 4)),
        close_quietly(S)
    end).

tls_client(Port, Token) ->
    %% verify_none: the certificate is self-signed and generated by the
    %% test. What matters here is that TLS is in use, not that this
    %% particular certificate chains to a trusted root.
    Opts = [binary, {active, false}, {packet, 4}, {verify, verify_none}],
    {ok, S} = ssl:connect("127.0.0.1", Port, Opts, 5000),
    {ok, <<?V2:8, ?HELLO_OK:8>>} = hello(S, ?V2, Token),
    S.

make_cert() ->
    Dir = filename:join("/tmp", "erl_bridge_tls_" ++
                              integer_to_list(erlang:unique_integer([positive]))),
    Cert = filename:join(Dir, "cert.pem"),
    Key = filename:join(Dir, "key.pem"),
    Command = lists:flatten(
                io_lib:format("mkdir -p ~s && openssl req -x509 -newkey "
                              "rsa:2048 -nodes -keyout ~s -out ~s -days 1 "
                              "-subj /CN=localhost -addext "
                              "subjectAltName=DNS:localhost,IP:127.0.0.1 "
                              "2>/dev/null", [Dir, Key, Cert])),
    _ = os:cmd(Command),
    case {filelib:is_regular(Cert), filelib:is_regular(Key)} of
        {true, true} -> {ok, Dir, Cert, Key};
        _ -> remove_dir(Dir), skip
    end.

remove_dir(Dir) ->
    _ = os:cmd("rm -rf " ++ Dir),
    ok.
