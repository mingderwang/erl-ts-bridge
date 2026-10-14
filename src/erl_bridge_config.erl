%%%-------------------------------------------------------------------
%%% @doc Builds and validates the {@link cfg()} record from three
%%% sources, in increasing order of precedence:
%%%
%%% <ol>
%%%   <li>the application environment (i.e. `sys.config'),</li>
%%%   <li>`ERL_BRIDGE_*' environment variables,</li>
%%%   <li>an explicit map of overrides passed by the caller.</li>
%%% </ol>
%%%
%%% The whole point of resolving this <em>once</em>, at startup, is that
%%% no long-lived process reads the environment at runtime. An operator
%%% exporting a variable must not silently reconfigure a server that is
%%% already serving traffic.
%%%
%%% Every field is validated here rather than at the point of use, so a
%%% bad value fails at boot with one clear message instead of surfacing
%%% as a confusing error in an acceptor ten seconds later.
%%% @end
%%%-------------------------------------------------------------------
-module(erl_bridge_config).

-include("erl_bridge.hrl").

-export([load/0, load/1, to_map/1, describe/1, default_acceptor_count/0]).

-export_type([cfg/0]).

%% A record does not define a type on its own; this is what lets other
%% modules write `-spec f(erl_bridge_config:cfg())'.
-type cfg() :: #cfg{}.

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Resolve configuration from the application environment and
%% environment variables only.
-spec load() -> {ok, cfg()} | {error, term()}.
load() ->
    load(#{}).

%% @doc Resolve configuration, applying `Overrides' on top.
%%
%% Accepts a map, a `#cfg{}' record or a proplist -- see normalise/1. No
%% guard on the argument type, because a guard would reject the record and
%% proplist forms before normalise/1 ever saw them.
-spec load(map() | #cfg{} | [{atom(), term()}]) -> {ok, cfg()} | {error, term()}.
load(Overrides) ->
    %% Precedence, lowest first: built-in defaults, the application
    %% environment, environment variables, then explicit overrides.
    Merged = merge(defaults(),
                   merge(application_env_settings(),
                         merge(env_vars(), normalise(Overrides)))),
    validate(coerce(Merged)).

%%%===================================================================
%%% Internal: coercion
%%%===================================================================

%% Environment variables are always strings, but the rest of this module
%% wants integers and booleans. Without this step ERL_BRIDGE_PORT=5005
%% fails validation with `invalid_port' and no environment variable can be
%% used for a numeric setting at all.
%%
%% A value that cannot be coerced is left alone rather than replaced, so
%% validation reports it with its original (string) value -- which is
%% more useful in an error message than "0" would be.
coerce(Settings) ->
    coerce_boolean(coerce_integers(Settings)).

coerce_integers(Settings) ->
    Fields = [port, acceptor_count, max_connections, max_frame_size,
              handshake_timeout, request_timeout, shutdown_grace,
              accept_timeout, metrics_port],
    lists:foldl(
      fun(Field, Acc) ->
              case Acc of
                  #{Field := Value} when is_binary(Value); is_list(Value) ->
                      case to_integer(Value) of
                          {ok, Integer} -> Acc#{Field => Integer};
                          error -> Acc
                      end;
                  _ ->
                      Acc
              end
      end, Settings, Fields).

coerce_boolean(Settings) ->
    case Settings of
        #{reuseport := Value} when is_binary(Value); is_list(Value) ->
            case Value of
                "true" -> Settings#{reuseport => true};
                "false" -> Settings#{reuseport => false};
                <<"true">> -> Settings#{reuseport => true};
                <<"false">> -> Settings#{reuseport => false};
                _ -> Settings
            end;
        _ ->
            Settings
    end.

%% os:getenv/1 returns a charlist; a value from sys.config may be either.
to_integer(Value) when is_binary(Value) -> to_integer(binary_to_list(Value));
to_integer(Value) ->
    try
        {ok, list_to_integer(Value)}
    catch
        _:_ -> error
    end.

%% @doc Flatten a config to a map. Used for logging and for supervisor
%% state, so callers do not have to know the record layout.
-spec to_map(cfg()) -> map().
to_map(#cfg{} = C) ->
    #{port => C#cfg.port,
      acceptor_count => C#cfg.acceptor_count,
      max_connections => C#cfg.max_connections,
      max_frame_size => C#cfg.max_frame_size,
      handshake_timeout => C#cfg.handshake_timeout,
      request_timeout => C#cfg.request_timeout,
      shutdown_grace => C#cfg.shutdown_grace,
      accept_timeout => C#cfg.accept_timeout,
      token => C#cfg.token,
      reuseport => C#cfg.reuseport,
      tls => C#cfg.tls,
      metrics_port => C#cfg.metrics_port}.

%% @doc The default acceptor count: one per scheduler, capped.
-spec default_acceptor_count() -> pos_integer().
default_acceptor_count() ->
    min(erlang:system_info(schedulers_online), ?DEFAULT_MAX_ACCEPTORS).

%% @doc A human-readable, secret-free rendering for the startup log.
%%
%% The token is reduced to a boolean and TLS to its enabled state on
%% purpose: this string is logged at boot and must never leak the secret.
-spec describe(cfg()) -> string().
describe(#cfg{} = C) ->
    lists:flatten(
      io_lib:format("port=~p reuseport=~p acceptors=~p max_connections=~p "
                    "max_frame=~p handshake_timeout=~p request_timeout=~p "
                    "auth=~s tls=~s metrics_port=~p",
                    [C#cfg.port, C#cfg.reuseport, acceptor_count(C),
                     C#cfg.max_connections, C#cfg.max_frame_size,
                     C#cfg.handshake_timeout, C#cfg.request_timeout,
                     auth_label(C), tls_label(C), C#cfg.metrics_port])).

%%%===================================================================
%%% Internal: sources
%%%===================================================================

defaults() ->
    #{port => ?DEFAULT_PORT,
      acceptor_count => undefined,
      max_connections => ?DEFAULT_MAX_CONNECTIONS,
      max_frame_size => ?DEFAULT_MAX_FRAME_SIZE,
      handshake_timeout => ?DEFAULT_HANDSHAKE_TIMEOUT,
      request_timeout => ?DEFAULT_REQUEST_TIMEOUT,
      shutdown_grace => ?DEFAULT_SHUTDOWN_GRACE,
      accept_timeout => ?DEFAULT_ACCEPT_TIMEOUT,
      token => undefined,
      reuseport => true,
      tls => undefined,
      metrics_port => undefined}.

%% application:get_all_env/1 returns a flat proplist for a single
%% application (only get_all_env/0 nests one list per application).
%%
%% The application is loaded first on purpose: bridge_server:start/1
%% validates before calling ensure_all_started/1, and without this a
%% sys.config setting would be invisible at exactly the moment it matters
%% -- silently falling back to defaults instead.
application_env_settings() ->
    _ = application:load(?APP),
    maps:filter(fun(_K, V) -> V =/= undefined end,
                maps:from_list(application:get_all_env(?APP))).

%% Environment variable names, written out in full rather than derived
%% from field names. Deriving them with atom_to_list/1 produced lowercase
%% names, and environment variables are case-sensitive on Unix -- so
%% ERL_BRIDGE_PORT was silently ignored and the server always used 4040.
%%
%% Note tls_certfile/tls_keyfile are not cfg fields; they are folded into
%% the `tls' option by tls/1 below.
env_vars() ->
    Vars = [{"ERL_BRIDGE_PORT", port},
            {"ERL_BRIDGE_ACCEPTORS", acceptor_count},
            {"ERL_BRIDGE_MAX_CONNECTIONS", max_connections},
            {"ERL_BRIDGE_MAX_FRAME_SIZE", max_frame_size},
            {"ERL_BRIDGE_HANDSHAKE_TIMEOUT", handshake_timeout},
            {"ERL_BRIDGE_REQUEST_TIMEOUT", request_timeout},
            {"ERL_BRIDGE_SHUTDOWN_GRACE", shutdown_grace},
            {"ERL_BRIDGE_TOKEN", token},
            {"ERL_BRIDGE_REUSEPORT", reuseport},
            {"ERL_BRIDGE_METRICS_PORT", metrics_port},
            {"ERL_BRIDGE_TLS_CERTFILE", tls_certfile},
            {"ERL_BRIDGE_TLS_KEYFILE", tls_keyfile}],
    lists:foldl(
      fun({Name, Field}, Acc) ->
              case os:getenv(Name) of
                  false -> Acc;
                  Value -> Acc#{Field => Value}
              end
      end, #{}, Vars).

%% Accept a record, a map or a proplist, because callers reasonably try
%% all three. Normalising here keeps every downstream stage map-shaped.
normalise(Overrides) ->
    case Overrides of
        #cfg{} = C -> to_map(C);
        M when is_map(M) -> M;
        L when is_list(L) -> maps:from_list(L)
    end.

%% `undefined' never overrides: it means "not set here", so that a lower
%% precedence source is not silently clobbered by an absent higher one.
merge(Low, High) ->
    lists:foldl(fun({K, V}, Acc) ->
                        case V of undefined -> Acc; _ -> Acc#{K => V} end
                end, Low, maps:to_list(High)).

%%%===================================================================
%%% Internal: validation
%%%===================================================================

validate(Settings) ->
    try
        {ok, #cfg{port = port(Settings),
                  acceptor_count = acceptor_count_setting(Settings),
                  max_connections = positive(Settings, max_connections),
                  max_frame_size = frame_size(Settings),
                  handshake_timeout = positive(Settings, handshake_timeout),
                  request_timeout = positive(Settings, request_timeout),
                  shutdown_grace = positive(Settings, shutdown_grace),
                  accept_timeout = positive(Settings, accept_timeout),
                  token = token(Settings),
                  reuseport = boolean(Settings),
                  tls = tls(Settings),
                  metrics_port = metrics_port(Settings)}}
    catch
        throw:{config_error, Reason} -> {error, Reason}
    end.

%% Every numeric field is a positive integer. Collected here rather than
%% repeated per field so the error text is identical everywhere.
%%
%% The key is looked up rather than matched in a map pattern because map
%% patterns require literal keys, and the whole point of this helper is
%% to take the key as an argument.
positive(Settings, Key) ->
    Value = maps:get(Key, Settings, undefined),
    case is_integer(Value) andalso Value > 0 of
        true -> Value;
        false -> throw({config_error, {invalid, Key, Value}})
    end.

%% Port 0 is legal and means "let the OS pick a free port". That is how the
%% test suite avoids colliding with a previous run's TIME_WAIT sockets, and
%% it is a reasonable thing for an ephemeral server to ask for.
port(#{port := P}) when is_integer(P), P >= 0, P < 65536 -> P;
port(#{port := P}) -> throw({config_error, {invalid_port, P}}).

%% Port 0 is allowed here too: "any free port". The endpoint reports the
%% real one via erl_bridge_metrics_http:port/0.
metrics_port(#{metrics_port := undefined}) -> undefined;
metrics_port(#{metrics_port := P}) when is_integer(P), P >= 0, P < 65536 -> P;
metrics_port(#{metrics_port := P}) ->
    throw({config_error, {invalid_metrics_port, P}}).

acceptor_count_setting(#{acceptor_count := undefined}) -> undefined;
acceptor_count_setting(Settings) -> positive(Settings, acceptor_count).
%% A frame cap below the largest legal request would reject every request,
%% so enforce a floor rather than accepting a configuration that cannot
%% possibly work. The floor comes from the protocol rather than being a
%% magic number, so it moves with the wire format.
frame_size(Settings) ->
    Minimum = erl_bridge_proto:max_request_bytes(),
    case positive(Settings, max_frame_size) of
        Size when Size < Minimum ->
            throw({config_error, {max_frame_size_too_small, Size, Minimum}});
        Size ->
            Size
    end.

%% Held as a binary so it can be compared in constant time with no
%% encoding step at the point of use.
token(#{token := undefined}) -> undefined;
token(#{token := T}) when is_binary(T), T =/= <<>> -> T;
token(#{token := T}) when is_list(T), T =/= [] -> list_to_binary(T);
token(#{token := T}) -> throw({config_error, {invalid_token, T}}).

boolean(#{reuseport := B}) when is_boolean(B) -> B;
boolean(#{reuseport := B}) -> throw({config_error, {invalid_reuseport, B}}).
%% TLS is assembled from the two file paths rather than accepted as a
%% pre-built option list: the interesting question is "which files", and
%% validating it here means a missing or unreadable file is a boot-time
%% error instead of an accept-loop error.
tls(#{tls := T}) when is_map(T) ->
    %% Matched with a case rather than `=': a bare match on a missing
    %% keyfile raises badmatch, which would escape validate/1's catch as
    %% a crash instead of a configuration error.
    case {maps:get(certfile, T, undefined), maps:get(keyfile, T, undefined)} of
        {C, K} when is_list(C), C =/= [], is_list(K), K =/= [] ->
            {ssl, [{certfile, C}, {keyfile, K}]};
        _Incomplete ->
            throw({config_error, {invalid_tls, T}})
    end;
tls(#{tls_certfile := C, tls_keyfile := K})
  when is_list(C), C =/= [], is_list(K), K =/= [] ->
    {ssl, [{certfile, C}, {keyfile, K}]};
tls(#{tls := T}) when T =/= undefined ->
    throw({config_error, {invalid_tls, T}});
tls(_) ->
    undefined.

%%%===================================================================
%%% Internal: presentation
%%%===================================================================

acceptor_count(#cfg{acceptor_count = undefined}) -> default_acceptor_count();
acceptor_count(#cfg{acceptor_count = N}) -> N.

auth_label(#cfg{token = undefined}) -> "disabled";
auth_label(#cfg{}) -> "token".

tls_label(#cfg{tls = undefined}) -> "disabled";
tls_label(#cfg{}) -> "enabled".
