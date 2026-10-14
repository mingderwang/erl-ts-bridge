%%%-------------------------------------------------------------------
%%% @doc Top-level supervisor.
%%%
%%% Child order matters. Metrics must be alive before anything can
%%% increment a counter, and the HTTP endpoint must start only after
%%% metrics, so a scrape never lands on a half-built node.
%%%
%%% Acceptors come last and are `permanent': if the acceptor supervisor
%%% cannot bind, `start_link/2' returns that error to the caller rather
%%% than crashing the node. A port conflict is an operator problem, not a
%%% bug to retry into a restart loop.
%%% @end
%%%-------------------------------------------------------------------
-module(erl_bridge_sup).

-behaviour(supervisor).

-include("erl_bridge.hrl").

-export([start_link/1]).

-export([init/1]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link(erl_bridge_config:cfg()) -> {ok, pid()} | {error, term()}.
start_link(Cfg) ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, [Cfg]).

%%%===================================================================
%%% supervisor
%%%===================================================================

init([Cfg]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    MetricsChild =
        #{id => erl_bridge_metrics,
          start => {erl_bridge_metrics, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [erl_bridge_metrics]},
    AcceptorChild =
        #{id => acceptor_sup,
          start => {erl_bridge_acceptor_sup, start_link, [Cfg]},
          restart => permanent,
          %% Long enough for in-flight requests to be answered, short
          %% enough that a restart does not look like a hang.
          shutdown => Cfg#cfg.shutdown_grace,
          type => supervisor,
          modules => [erl_bridge_acceptor_sup]},
    Children = [MetricsChild] ++ metrics_http_children(Cfg) ++ [AcceptorChild],
    {ok, {SupFlags, Children}}.

%% The metrics endpoint is optional. It is started under the same
%% supervisor, so a bind failure there does take the node down -- which
%% is the right call: an operator who asked for metrics and cannot get
%% them should find out loudly rather than scrape an empty port.
metrics_http_children(#cfg{metrics_port = undefined}) ->
    [];
metrics_http_children(#cfg{metrics_port = Port}) ->
    [#{id => erl_bridge_metrics_http,
       start => {erl_bridge_metrics_http, start_link, [Port]},
       restart => permanent,
       shutdown => 5000,
       type => worker,
       modules => [erl_bridge_metrics_http]}].
