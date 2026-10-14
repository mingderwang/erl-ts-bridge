%%%-------------------------------------------------------------------
%%% @doc OTP application callback.
%%%
%%% Resolves configuration once, at boot, and publishes the result in the
%%% application environment so that {@link bridge_server:info/0} can
%%% report what the server is actually running with rather than
%%% re-deriving it -- which could disagree with reality if an environment
%%% variable changed since start.
%%% @end
%%%-------------------------------------------------------------------
-module(erl_bridge_app).

-behaviour(application).

-include("erl_bridge.hrl").

-export([start/2, stop/1]).

%%%===================================================================
%%% application
%%%===================================================================

start(_Type, _Args) ->
    %% bridge_server:start/1 stashes the caller's overrides here so that
    %% starting the application resolves exactly the configuration the
    %% caller asked for, rather than silently ignoring it.
    Overrides = application:get_env(?APP, overrides, #{}),
    case erl_bridge_config:load(Overrides) of
        {ok, Cfg} ->
            %% Published before the supervisor starts: a scrape or an
            %% info/0 call that arrives during boot sees the real config
            %% rather than nothing.
            application:set_env(?APP, resolved_config, Cfg),
            erl_bridge_sup:start_link(Cfg);
        {error, Reason} ->
            logger:error("erl_bridge: invalid configuration: ~p", [Reason]),
            {error, {bad_config, Reason}}
    end.

stop(_State) ->
    ok.
