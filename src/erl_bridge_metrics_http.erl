%%%-------------------------------------------------------------------
%%% @doc A minimal `/metrics' HTTP endpoint for Prometheus to scrape.
%%%
%%% This is deliberately not Cowboy. The endpoint serves exactly one
%%% static route, returns exactly one body, and must never be able to
%%% affect the request-serving path. Pulling in a web framework (and its
%%% transitive dependencies) to replace fifty lines of `gen_tcp' would be a
%%% poor trade, especially since the whole surface fits on one screen.
%%%
%%% <b>Structure: a gen_server that owns a linked accept worker.</b> The
%%% gen_server holds the listening socket, answers `port/0' and `stop/0',
%%% and restarts the worker if it dies. The worker runs a plain blocking
%%% accept loop, because driving a blocking accept from inside a gen_server
%%% callback requires a timeout message to re-arm the loop between
%%% iterations -- and that arrangement proved fragile. One small process
%%% with a straightforward loop has no such subtlety.
%%%
%%% An event-driven accept is not available here in any case:
%%% `{active, true}' and `{active, once}' on a <b>listening</b> socket
%%% deliver nothing in OTP 29 (verified -- no `{tcp, ListenSocket, _}'
%%% ever arrives), and `prim_inet:async_accept/1' is not publicly
%%% reachable. Blocking accept with a timeout is the only option.
%%%
%%% <b>Security note.</b> This listener serves unauthenticated metrics to
%%% whoever can reach it, and it binds to loopback only. Metric names,
%%% labels and counts leak traffic shape, so do not expose it publicly: if
%%% a remote host must scrape it, put a reverse proxy that authenticates
%%% in front.
%%% @end
%%%-------------------------------------------------------------------
-module(erl_bridge_metrics_http).

-behaviour(gen_server).

-include("erl_bridge.hrl").

-export([start_link/1, stop/0, port/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(MAX_REQUEST_BYTES, 8192).
-define(REQUEST_TIMEOUT, 5000).

-record(state, {listen_socket :: gen_tcp:socket(),
                port :: inet:port_number() | undefined,
                worker :: pid() | undefined}).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link(inet:port_number()) -> {ok, pid()} | {error, term()}.
start_link(Port) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Port], []).

-spec stop() -> ok.
stop() ->
    gen_server:call(?SERVER, stop).

%% @doc The bound port. Useful when starting on port 0 in tests.
-spec port() -> inet:port_number() | undefined.
port() ->
    try gen_server:call(?SERVER, port)
    catch exit:_ -> undefined
    end.

%%%===================================================================
%%% gen_server
%%%===================================================================

init([Port]) ->
    process_flag(trap_exit, true),
    %% Loopback only -- see the security note in the module docs.
    %% {active, false} is essential, not stylistic. gen_tcp:listen
    %% DEFAULTS to {active, true}; an accepted socket inherits the
    %% listening socket's mode; and gen_tcp:recv/3 on an active-mode
    %% socket fails with {error, einval}. Without this option the
    %% endpoint accepts connections and then silently reads nothing.
    Opts = [binary, {active, false}, {reuseaddr, true}, {backlog, 16},
            {ip, {127, 0, 0, 1}}],
    case gen_tcp:listen(Port, Opts) of
        {ok, ListenSocket} ->
            {ok, Actual} = inet:port(ListenSocket),
            logger:info("metrics endpoint listening on 127.0.0.1:~p", [Actual]),
            {ok, State} = start_worker(ListenSocket,
                                       #state{listen_socket = ListenSocket,
                                              port = Actual}),
            {ok, State};
        {error, Reason} ->
            {stop, {metrics_listen_failed, Reason}}
    end.

handle_call(port, _From, #state{port = Port} = State) ->
    {reply, Port, State};
handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% The accept worker died. Restart it: a scrape endpoint that stops
%% answering after an unrelated failure is worse than useless, because a
%% monitoring system treats silence as "healthy".
handle_info({'EXIT', Worker, Reason}, #state{worker = Worker} = State) ->
    case Reason of
        shutdown ->
            {stop, shutdown, State};
        normal ->
            logger:warning("metrics accept worker stopped; restarting"),
            {ok, State1} = start_worker(State#state.listen_socket, State),
            {noreply, State1};
        _ ->
            logger:warning("metrics accept worker crashed (~p); restarting",
                           [Reason]),
            {ok, State1} = start_worker(State#state.listen_socket, State),
            {noreply, State1}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{listen_socket = S}) ->
    %% Closing the listen socket makes the worker's blocking accept return
    %% `closed', at which point it exits.
    gen_tcp:close(S),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal
%%%===================================================================

start_worker(ListenSocket, State) ->
    %% spawn_link/3 returns a bare pid, not {ok, Pid}. The link is wanted:
    %% it is what delivers the worker's death to handle_info/2 so the
    %% worker can be restarted rather than silently disappearing.
    Pid = spawn_link(fun() -> accept_loop(ListenSocket) end),
    {ok, State#state{worker = Pid}}.

%% The whole accept loop, in one plain process.
accept_loop(ListenSocket) ->
    case gen_tcp:accept(ListenSocket, ?DEFAULT_ACCEPT_TIMEOUT) of
        {ok, Socket} ->
            serve(Socket);
        {error, closed} ->
            %% The listen socket was closed: we are shutting down.
            exit(shutdown);
        {error, _Reason} ->
            %% `timeout' is the normal case. Nothing to report.
            ok
    end,
    accept_loop(ListenSocket).

%% Answer one request and close the socket.
%%
%% Both waits are bounded, so a client that connects and then stalls costs
%% one loop iteration and no more. The `after' matters: a client that
%% disconnects mid-request must not leak a socket.
serve(Socket) ->
    try
        case gen_tcp:recv(Socket, 0, ?REQUEST_TIMEOUT) of
            {ok, Request} -> handle_request(Socket, Request);
            {error, _Reason} -> ok
        end
    after
        gen_tcp:close(Socket)
    end.

%% Only the request line is inspected: this endpoint takes no parameters,
%% so parsing headers or a body would be scope with no purpose.
handle_request(Socket, Data) when byte_size(Data) > ?MAX_REQUEST_BYTES ->
    respond(Socket, 431, "Request Header Fields Too Large", <<>>, false);
handle_request(Socket, Data) ->
    case parse_request(Data) of
        {Method, <<"/metrics">>} when Method =:= "GET"; Method =:= "HEAD" ->
            respond(Socket, 200, "OK", erl_bridge_metrics:scrape(),
                    Method =:= "HEAD");
        {_Method, <<"/metrics">>} ->
            respond(Socket, 405, "Method Not Allowed", <<>>, false);
        {_Method, _Other} ->
            respond(Socket, 404, "Not Found", <<>>, false);
        malformed ->
            respond(Socket, 400, "Bad Request", <<>>, false)
    end.

parse_request(Data) ->
    case binary:split(Data, <<" ">>, [global]) of
        [Method, Path | _] -> {binary_to_list(Method), trim_eol(Path)};
        _ -> malformed
    end.

trim_eol(Bin) ->
    case binary:match(Bin, <<"\r">>) of
        {Pos, _} -> binary:part(Bin, 0, Pos);
        nomatch ->
            case binary:match(Bin, <<"\n">>) of
                {Pos, _} -> binary:part(Bin, 0, Pos);
                nomatch -> Bin
            end
    end.

%% A HEAD reply carries the headers the equivalent GET would have, but no
%% body -- so send headers only.
%%
%% The socket is not closed here; serve/1 owns that, so one place is
%% responsible for the socket's lifetime.
respond(Socket, Code, Reason, Body, HeadOnly) ->
    Headers =
        io_lib:format("HTTP/1.1 ~p ~s\r\n"
                      "Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n"
                      "Content-Length: ~p\r\n"
                      "Connection: close\r\n\r\n",
                      [Code, Reason, byte_size(Body)]),
    Payload =
        case HeadOnly of
            true -> iolist_to_binary(Headers);
            false -> iolist_to_binary([Headers, Body])
        end,
    _ = gen_tcp:send(Socket, Payload),
    ok.
