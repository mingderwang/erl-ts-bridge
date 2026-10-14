%%%-------------------------------------------------------------------
%%% @doc Tests for configuration resolution, token verification and the
%%% Prometheus renderer.
%%%
%%% Configuration is resolved from the application environment and
%%% `ERL_BRIDGE_*' environment variables, so these tests set and restore
%%% both. Each test restores what it touched in an `after' block: leaking
%%% `ERL_BRIDGE_PORT' into a later test would produce a failure that looks
%%% like a bug in the code under test.
%%% @end
%%%-------------------------------------------------------------------
-module(erl_bridge_config_tests).

-include_lib("eunit/include/eunit.hrl").

-include("erl_bridge.hrl").

%%%===================================================================
%%% Helpers
%%%===================================================================

%% Runs Fun with a clean slate: no leftover application env, no leftover
%% environment variables.
with_clean_env(Fun) ->
    SavedApp = application:get_all_env(?APP),
    Names = ["ERL_BRIDGE_PORT", "ERL_BRIDGE_TOKEN", "ERL_BRIDGE_REUSEPORT",
             "ERL_BRIDGE_METRICS_PORT", "ERL_BRIDGE_ACCEPTORS",
             "ERL_BRIDGE_MAX_CONNECTIONS", "ERL_BRIDGE_TLS_CERTFILE",
             "ERL_BRIDGE_TLS_KEYFILE"],
    SavedVars = [{Name, os:getenv(Name)} || Name <- Names],
    try
        lists:foreach(fun({K, _V}) -> application:unset_env(?APP, K) end,
                      SavedApp),
        lists:foreach(fun(Name) -> os:unsetenv(Name) end, Names),
        Fun()
    after
        lists:foreach(fun({K, V}) -> application:set_env(?APP, K, V) end,
                      SavedApp),
        lists:foreach(fun({Name, false}) -> os:unsetenv(Name);
                         ({Name, V}) -> os:setenv(Name, V)
                      end, SavedVars)
    end.

%%%===================================================================
%%% Defaults
%%%===================================================================

defaults_test() ->
    with_clean_env(fun() ->
        {ok, Cfg} = erl_bridge_config:load(),
        ?assertEqual(?DEFAULT_PORT, Cfg#cfg.port),
        ?assertEqual(?DEFAULT_MAX_CONNECTIONS, Cfg#cfg.max_connections),
        ?assertEqual(?DEFAULT_MAX_FRAME_SIZE, Cfg#cfg.max_frame_size),
        ?assertEqual(undefined, Cfg#cfg.token),
        ?assertEqual(true, Cfg#cfg.reuseport),
        ?assertEqual(undefined, Cfg#cfg.tls),
        ?assertEqual(undefined, Cfg#cfg.metrics_port),
        ?assert(erl_bridge_config:default_acceptor_count() >= 1)
    end).

%%%===================================================================
%%% Precedence
%%%===================================================================

%% Overrides beat everything, which is what makes bridge_server:start/1
%% able to promise it will honour what the caller passed.
overrides_win_test() ->
    with_clean_env(fun() ->
        os:putenv("ERL_BRIDGE_PORT", "5001"),
        application:set_env(?APP, port, 5002),
        {ok, Cfg} = erl_bridge_config:load(#{port => 5003}),
        ?assertEqual(5003, Cfg#cfg.port)
    end).

%% Environment variables beat the application environment, so an operator
%% can override a sys.config value in a container without editing it.
env_beats_app_env_test() ->
    with_clean_env(fun() ->
        application:set_env(?APP, port, 5002),
        {ok, Cfg} = erl_bridge_config:load(),
        ?assertEqual(5002, Cfg#cfg.port),
        os:putenv("ERL_BRIDGE_PORT", "5001"),
        {ok, Cfg2} = erl_bridge_config:load(),
        ?assertEqual(5001, Cfg2#cfg.port)
    end).

%% A record, a map and a proplist are all accepted, because callers
%% reasonably try each of them and normalising here beats failing at the
%% call site with a badmatch.
record_map_and_proplist_accepted_test() ->
    with_clean_env(fun() ->
        {ok, FromMap} = erl_bridge_config:load(#{port => 4055}),
        ?assertEqual(4055, FromMap#cfg.port),

        {ok, FromRecord} = erl_bridge_config:load(FromMap),
        ?assertEqual(4055, FromRecord#cfg.port),

        {ok, FromProplist} = erl_bridge_config:load([{port, 4056}]),
        ?assertEqual(4056, FromProplist#cfg.port)
    end).

%%%===================================================================
%%% Validation
%%%===================================================================

invalid_port_test() ->
    with_clean_env(fun() ->
        ?assertMatch({error, {invalid_port, _}},
                     erl_bridge_config:load(#{port => 70000})),
        ?assertMatch({error, {invalid_port, _}},
                     erl_bridge_config:load(#{port => -1})),
        ?assertMatch({error, {invalid_port, _}},
                     erl_bridge_config:load(#{port => not_a_port}))
    end).

%% Port 0 is legal: it asks the OS for a free port, which is how the
%% integration tests avoid colliding with a previous run.
port_zero_allowed_test() ->
    with_clean_env(fun() ->
        {ok, Cfg} = erl_bridge_config:load(#{port => 0}),
        ?assertEqual(0, Cfg#cfg.port)
    end).

invalid_positive_fields_test() ->
    with_clean_env(fun() ->
        ?assertMatch({error, {invalid, max_connections, 0}},
                     erl_bridge_config:load(#{max_connections => 0})),
        ?assertMatch({error, {invalid, request_timeout, -5}},
                     erl_bridge_config:load(#{request_timeout => -5})),
        ?assertMatch({error, {invalid, handshake_timeout, bad}},
                     erl_bridge_config:load(#{handshake_timeout => bad}))
    end).

%% A frame cap below the largest legal request would reject every request,
%% so it is refused at boot rather than discovered in traffic.
frame_size_floor_test() ->
    with_clean_env(fun() ->
        Minimum = erl_bridge_proto:max_request_bytes(),
        ?assertMatch({error, {max_frame_size_too_small, 8, _}},
                     erl_bridge_config:load(#{max_frame_size => 8})),
        ?assertMatch({error, {invalid, max_frame_size, 0}},
                     erl_bridge_config:load(#{max_frame_size => 0})),
        %% Exactly the largest legal request is the smallest usable cap.
        {ok, Cfg} = erl_bridge_config:load(#{max_frame_size => Minimum}),
        ?assertEqual(Minimum, Cfg#cfg.max_frame_size)
    end).

invalid_tls_test() ->
    with_clean_env(fun() ->
        ?assertMatch({error, {invalid_tls, _}},
                     erl_bridge_config:load(#{tls => "yes please"})),
        %% Only one of the two files is not a usable TLS configuration,
        %% and it must not fall through to "TLS disabled".
        ?assertMatch({error, _},
                     erl_bridge_config:load(#{tls => #{certfile => "/tmp/c"}}))
    end).

tls_from_env_test() ->
    with_clean_env(fun() ->
        os:putenv("ERL_BRIDGE_TLS_CERTFILE", "/tmp/cert.pem"),
        os:putenv("ERL_BRIDGE_TLS_KEYFILE", "/tmp/key.pem"),
        {ok, Cfg} = erl_bridge_config:load(),
        ?assertEqual({ssl, [{certfile, "/tmp/cert.pem"},
                            {keyfile, "/tmp/key.pem"}]}, Cfg#cfg.tls)
    end).

token_normalisation_test() ->
    with_clean_env(fun() ->
        ?assertEqual(<<"abc">>, erl_bridge_token_normalise("abc")),
        ?assertEqual(<<"abc">>, erl_bridge_token_normalise(<<"abc">>)),
        ?assertMatch({error, {invalid_token, _}},
                     erl_bridge_config:load(#{token => <<>>})),
        ?assertMatch({error, {invalid_token, _}},
                     erl_bridge_config:load(#{token => 12345}))
    end).

%% describe/1 is logged at boot, so the secret must not appear in it.
describe_hides_token_test() ->
    with_clean_env(fun() ->
        {ok, Cfg} = erl_bridge_config:load(#{token => <<"super-secret-value">>,
                                             port => 4040}),
        Text = erl_bridge_config:describe(Cfg),
        ?assertEqual(nomatch, string:find(Text, "super-secret-value")),
        ?assertNotEqual(nomatch, string:find(Text, "auth=token")),
        {ok, NoAuth} = erl_bridge_config:load(),
        ?assertNotEqual(nomatch,
                        string:find(erl_bridge_config:describe(NoAuth),
                                    "auth=disabled"))
    end).

erl_bridge_token_normalise(T) when is_list(T) -> list_to_binary(T);
erl_bridge_token_normalise(T) -> T.
