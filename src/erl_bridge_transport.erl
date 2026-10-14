%%%-------------------------------------------------------------------
%%% @doc Thin dispatch layer over `gen_tcp' and `ssl'.
%%%
%%% TLS is optional, so every socket call has to branch on which module
%%% owns the socket. Doing that branching in one place keeps it out of
%%% the acceptor and connection processes, which otherwise have to carry
%%% a "which module?" flag through every call for no benefit.
%%%
%%% Both modules accept the same inet options (`{packet, 4}',
%%% `{active, false}', `{reuseport, true}', ...), so the listen options
%%% built here are valid for either.
%%% @end
%%%-------------------------------------------------------------------
-module(erl_bridge_transport).

-include("erl_bridge.hrl").

-export([listen/2, accept/2, controlling_process/2,
         close/1, send/2, recv/3, peername/1, setopts/2, port/1]).

-type socket() :: {gen_tcp, gen_tcp:socket()} | {ssl, ssl:sslsocket()}.
-export_type([socket/0]).

%%%===================================================================
%%% Listen / accept
%%%===================================================================

%% @doc Open a listening socket.
%%
%% `{reuseport, false}' is what makes a duplicate launch on the same port
%% fail loudly with `eaddrinuse' instead of silently succeeding; see the
%% README for why that trade-off is configurable.
-spec listen(inet:port_number(), #cfg{}) -> {ok, socket()} | {error, term()}.
listen(Port, #cfg{} = Cfg) ->
    Opts = listen_opts(Cfg),
    case tls_opts(Cfg) of
        undefined ->
            case gen_tcp:listen(Port, Opts) of
                {ok, S} -> {ok, {gen_tcp, S}};
                {error, _} = E -> E
            end;
        SslOpts ->
            case ssl:listen(Port, Opts ++ SslOpts) of
                {ok, S} -> {ok, {ssl, S}};
                {error, _} = E -> E
            end
    end.

listen_opts(#cfg{max_frame_size = MaxFrame, reuseport = Reuseport}) ->
    [binary,
     {packet, 4},
     {packet_size, MaxFrame},
     {active, false},
     %% Always set: without it a listener in TIME_WAIT makes an
     %% otherwise-idle restart fail.
     {reuseaddr, true},
     {reuseport, Reuseport},
     {backlog, 128}].

tls_opts(#cfg{tls = undefined}) -> undefined;
tls_opts(#cfg{tls = {ssl, Opts}}) -> Opts.

%% @doc Accept one connection.
%%
%% For TLS this performs the handshake too, so a slow or hostile client
%% is bounded by `Timeout' rather than blocking an acceptor indefinitely.
%%
%% OTP's TLS server API is two steps, not one: `ssl:transport_accept/2'
%% accepts the TCP connection and returns a bare transport socket, then
%% `ssl:handshake/2' upgrades it. There is no `ssl:accept/2' -- it no
%% longer exists, and calling it fails with `undef' on the first
%% connection rather than at compile time.
-spec accept(socket(), timeout()) ->
                    {ok, socket()} | {error, term()}.
accept({gen_tcp, S}, Timeout) ->
    case gen_tcp:accept(S, Timeout) of
        {ok, C} -> {ok, {gen_tcp, C}};
        {error, _} = E -> E
    end;
accept({ssl, S}, Timeout) ->
    case ssl:transport_accept(S, Timeout) of
        {ok, Transport} ->
            case ssl:handshake(Transport, Timeout) of
                {ok, C} -> {ok, {ssl, C}};
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end.

%% @doc Transfer socket ownership to another process.
%%
%% Must happen before the worker is told about the socket, and before
%% the acceptor closes its own copy. For TLS the socket also has to be
%% put into passive mode explicitly: `ssl:controlling_process/2' does not
%% carry the acceptor's `{active, false}' across.
-spec controlling_process(socket(), pid()) -> ok | {error, term()}.
controlling_process({gen_tcp, S}, Pid) ->
    gen_tcp:controlling_process(S, Pid);
controlling_process({ssl, S}, Pid) ->
    case ssl:controlling_process(S, Pid) of
        ok -> ssl:setopts(S, [{active, false}]);
        {error, _} = E -> E
    end.

%%%===================================================================
%%% Per-connection operations
%%%===================================================================

-spec close(socket()) -> ok.
close({gen_tcp, S}) -> gen_tcp:close(S);
close({ssl, S}) -> ssl:close(S).

-spec send(socket(), binary()) -> ok | {error, term()}.
send({gen_tcp, S}, Data) -> gen_tcp:send(S, Data);
send({ssl, S}, Data) -> ssl:send(S, Data).

-spec recv(socket(), non_neg_integer(), timeout()) ->
                  {ok, binary()} | {error, term()}.
recv({gen_tcp, S}, Length, Timeout) -> gen_tcp:recv(S, Length, Timeout);
recv({ssl, S}, Length, Timeout) -> ssl:recv(S, Length, Timeout).

%% @doc The peer's address, rendered as a string.
%%
%% Returns `"unknown"' rather than an error tuple so log formatting never
%% has to cope with a nested failure on an error path.
-spec peername(socket()) -> string().
peername({gen_tcp, S}) -> format_peer(inet:peername(S));
peername({ssl, S}) -> format_peer(ssl:peername(S)).

%% @doc The local port the socket is bound to, as a bare integer.
%%
%% Needed because a listener opened on port 0 is assigned one by the OS,
%% and the configuration record still says 0 until this is read back.
%%
%% Both underlying calls wrap their answer in an `ok' tuple -- inet:port/1
%% gives `{ok, Port}' while ssl:sockname/1 gives `{ok, {Address, Port}}' --
%% so they are unwrapped here rather than leaking two different shapes to
%% the caller.
-spec port(socket()) -> inet:port_number() | undefined.
port({gen_tcp, S}) ->
    case inet:port(S) of
        {ok, Port} -> Port;
        _ -> undefined
    end;
port({ssl, S}) ->
    case ssl:sockname(S) of
        {ok, {_Address, Port}} -> Port;
        _ -> undefined
    end.

-spec setopts(socket(), [gen_tcp:option()]) -> ok | {error, term()}.
setopts({gen_tcp, S}, Opts) -> inet:setopts(S, Opts);
setopts({ssl, S}, Opts) -> ssl:setopts(S, Opts).

%%%===================================================================
%%% Internal
%%%===================================================================

format_peer({ok, {Address, Port}}) ->
    lists:flatten(io_lib:format("~s:~w", [inet:ntoa(Address), Port]));
format_peer(_) ->
    "unknown".
