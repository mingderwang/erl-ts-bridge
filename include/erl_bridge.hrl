%%%-------------------------------------------------------------------
%%% @doc Shared records, protocol constants and compile-time limits.
%%%
%%% This header is internal; nothing here is part of the public API.
%%% @end
%%%-------------------------------------------------------------------
-ifndef(ERL_BRIDGE_HRL).
-define(ERL_BRIDGE_HRL, true).

-define(APP, erl_bridge).

%%%-------------------------------------------------------------------
%%% Protocol (see PROTOCOL.md)
%%%-------------------------------------------------------------------

%% Version 2 added the mandatory HELLO handshake (version negotiation +
%% auth) before any request is accepted. Version 1 was unauthenticated
%% and is no longer accepted at all, which is why this is a break.
-define(PROTO_VERSION_MIN, 2).
-define(PROTO_VERSION_MAX, 2).

%% Opcode values in a request payload.
-define(OP_ADD, 1).

%% HELLO_ACK status codes. A distinct code per rejection reason matters:
%% a single "rejected" tells an operator nothing, and it is safe to send
%% because it reveals nothing about the token.
-define(HELLO_OK, 0).
-define(HELLO_BAD_VERSION, 1).
-define(HELLO_AUTH_FAILED, 2).

%% Refuse absurd token sizes outright rather than buffering them. A real
%% token is 32+ random bytes; 512 leaves generous headroom while still
%% bounding what a hostile peer can make us hold in memory.
-define(MAX_TOKEN_BYTES, 512).

%% Shortest legal HELLO: version(1) + token length(2) + empty token.
%% An empty token is accepted by the decoder; whether one is *required*
%% is decided by the authentication step, not here.
-define(HELLO_MIN_BYTES, 3).
-define(HELLO_MAX_BYTES, 3 + ?MAX_TOKEN_BYTES).

%%%-------------------------------------------------------------------
%%% Compile-time limits (defaults; all overridable at runtime)
%%%-------------------------------------------------------------------

-define(DEFAULT_PORT, 4040).
-define(DEFAULT_MAX_CONNECTIONS, 128).
-define(DEFAULT_MAX_FRAME_SIZE, 1048576).      %% 1 MiB
-define(DEFAULT_HANDSHAKE_TIMEOUT, 5000).      %% 5 s
-define(DEFAULT_REQUEST_TIMEOUT, 30000).       %% 30 s
-define(DEFAULT_SHUTDOWN_GRACE, 5000).         %% 5 s
-define(DEFAULT_ACCEPT_TIMEOUT, 1000).         %% 1 s
-define(DEFAULT_MAX_ACCEPTORS, 8).

%%%-------------------------------------------------------------------
%%% Metrics
%%%-------------------------------------------------------------------

%% Every metric the server maintains, pre-seeded at zero so Prometheus
%% sees a series before it is ever touched. Keep this list and the
%% update sites in sync: a metric here that nothing updates is dead
%% weight, and one updated but absent here still works but appears late.
%%
%% counter = monotonic, rendered with a _total suffix.
%% gauge   = may go up and down, rendered bare.
-define(METRICS, [{connections_accepted, counter},
                  {connections_active, gauge},
                  {connections_rejected_cap, counter},
                  {connections_closed, counter},
                  {requests_ok, counter},
                  {requests_overflow, counter},
                  {requests_bad_opcode, counter},
                  {requests_malformed, counter},
                  {handshake_ok, counter},
                  {handshake_bad_version, counter},
                  {handshake_auth_failed, counter},
                  {handshake_malformed, counter},
                  {handshake_timeout, counter}]).

%%%-------------------------------------------------------------------
%%% Configuration
%%%-------------------------------------------------------------------

%% @doc Fully resolved, validated runtime configuration.
%%
%% Built once in {@link erl_bridge_config:load/1} from the application
%% environment, environment variables and explicit overrides, then
%% handed to each process. Never read the environment at runtime from a
%% long-lived process: a reconfigured env var should not silently change
%% the behaviour of an already-running server.
-record(cfg, {
          port = ?DEFAULT_PORT :: inet:port_number(),
          acceptor_count :: pos_integer() | undefined,
          max_connections = ?DEFAULT_MAX_CONNECTIONS :: pos_integer(),
          max_frame_size = ?DEFAULT_MAX_FRAME_SIZE :: pos_integer(),
          handshake_timeout = ?DEFAULT_HANDSHAKE_TIMEOUT :: timeout(),
          request_timeout = ?DEFAULT_REQUEST_TIMEOUT :: timeout(),
          shutdown_grace = ?DEFAULT_SHUTDOWN_GRACE :: timeout(),
          accept_timeout = ?DEFAULT_ACCEPT_TIMEOUT :: timeout(),

          %% undefined disables authentication. That is a deliberate,
          %% logged choice, not an oversight -- see erl_bridge_sup.
          token :: binary() | undefined,

          %% SO_REUSEPORT lets several instances bind one port. Turning it
          %% off is the only way to make a duplicate launch a hard error.
          reuseport = true :: boolean(),

          %% undefined disables TLS entirely.
          tls :: {ssl, [{ssl, ssl:tls_server_option()}]} | undefined,

          %% undefined disables the metrics endpoint.
          metrics_port :: inet:port_number() | undefined
         }).

-endif.
