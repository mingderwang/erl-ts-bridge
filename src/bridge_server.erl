%%%-------------------------------------------------------------------
%%% @doc Public entry point for the erl_bridge server.
%%%
%%% <b>Why this module exists.</b> The server is an OTP application, so
%%% the honest way to run it is `application:ensure_all_started/1'. This
%%% module wraps that with argument validation and a friendlier call, and
%%% is the only module a caller needs to know about.
%%%
%%% <b>On naming.</b> The pre-2.0 API exposed `start_link/1,2,3', which
%%% was a misnomer: it spawned processes and returned their pids, but it
%%% was not a `gen_server' and had no supervision tree. The functions are
%%% now `start/0,1' and they start a supervised application. The old
%%% `start_link/N' names are kept as deprecated aliases so existing
%%% callers keep working, but they will be removed in 3.0 -- see
%%% {@link deprecated/0}.
%%%
%%% `start/1' and `start/2' return `ok', not a pid. There is no single pid
%%% to return: the entry point is a supervisor with a tree beneath it.
%%% Call {@link info/0} for the child pids.
%%% @end
%%%-------------------------------------------------------------------
-module(bridge_server).

-include("erl_bridge.hrl").

-export([start/0, start/1, start/2,
         stop/0, running/0, info/0,
         generate_token/1]).

%% Deprecated aliases. Kept so existing callers do not break on upgrade;
%% they will be removed in 3.0.
-export([start_link/0, start_link/1, start_link/2]).

-deprecated([{start_link, 0, "use start/0 instead"},
             {start_link, 1, "use start/1 instead"},
             {start_link, 2, "use start/2 instead"}]).

%%%===================================================================
%%% API
%%%===================================================================

%% @equiv start(#{})
-spec start() -> ok | {error, term()}.
start() ->
    start(#{}).

%% @doc Start the server, overriding the resolved configuration.
%%
%% `Overrides' accepts the keys documented in
%% {@link erl_bridge_config:load/1}: `port', `token', `max_connections',
%% `tls', `metrics_port' and so on.
-spec start(map()) -> ok | {error, term()}.
start(Overrides) ->
    start(Overrides, []).

%% @doc As {@link start/1}, with extra application start arguments.
-spec start(map(), [term()]) -> ok | {error, term()}.
start(Overrides, _AppArgs) ->
    case erl_bridge_config:load(Overrides) of
        {ok, _Cfg} ->
            %% Stash the caller's overrides so erl_bridge_app:start/2
            %% resolves exactly the same configuration the caller asked
            %% for, rather than re-reading the environment and silently
            %% ignoring what was passed here.
            application:set_env(?APP, overrides, Overrides),
            %% Normalised to ok: ensure_all_started/1 answers {ok, Apps},
            %% and on a second call the list is empty. Callers want to know
            %% whether the server is up, not which applications it had to
            %% start this time.
            case application:ensure_all_started(?APP) of
                {ok, _Started} -> ok;
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, {bad_config, Reason}}
    end.

%% @doc Stop the server and everything under it.
%%
%% Connection workers are shut down with a grace period, so in-flight
%% requests get a chance to be answered before their sockets close.
-spec stop() -> ok | {error, term()}.
stop() ->
    application:stop(?APP).

-spec running() -> boolean().
running() ->
    lists:keymember(?APP, 1, application:which_applications()).

%% @doc A snapshot of the running server: resolved config, child pids,
%% live connection count and metrics.
-spec info() -> map().
info() ->
    #{running => running(),
      config => application:get_env(?APP, resolved_config, undefined),
      children => children(),
      connections => erl_bridge_acceptor_sup:connection_count(),
      metrics => erl_bridge_metrics:describe()}.

%% @doc Generate a hex-encoded random token suitable for `token'.
-spec generate_token(pos_integer()) -> {ok, binary()} | {error, term()}.
generate_token(Bytes) ->
    erl_bridge_token:generate(Bytes).

%%%===================================================================
%%% Internal
%%%===================================================================

%% supervisor:which_children/1 returns a bare list in current OTP, not
%% `{ok, List}'. Matching the tuple form silently yields an empty map --
%% which is what dialyzer flagged: info/0 would report no children at all
%% while the server was perfectly healthy.
children() ->
    case whereis(erl_bridge_sup) of
        undefined ->
            #{};
        _Pid ->
            try
                maps:from_list(
                  [{Id, {Type, Pid}}
                   || {Id, Pid, Type, _Modules} <-
                          supervisor:which_children(erl_bridge_sup)])
            catch
                _:_ -> #{}
            end
    end.

%%%===================================================================
%%% Deprecated aliases
%%%===================================================================

%% @deprecated Use {@link start/0}.
-spec start_link() -> ok | {error, term()}.
start_link() -> start().

%% @deprecated Use {@link start/1}.
-spec start_link(map()) -> ok | {error, term()}.
start_link(Overrides) -> start(Overrides).

%% @deprecated Use {@link start/2}.
-spec start_link(map(), [term()]) -> ok | {error, term()}.
start_link(Overrides, AppArgs) -> start(Overrides, AppArgs).
