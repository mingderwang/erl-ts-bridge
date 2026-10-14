%%%-------------------------------------------------------------------
%%% @doc Tests for the metrics registry and its Prometheus rendering.
%%%
%%% The registry is a process with a named ETS table, so these tests own
%%% its lifecycle: start it, drive it, read it back. The HTTP endpoint
%%% that exposes it is covered separately in
%%% {@link erl_bridge_metrics_http_tests}.
%%% @end
%%%-------------------------------------------------------------------
-module(erl_bridge_metrics_tests).

-include_lib("eunit/include/eunit.hrl").

-include("erl_bridge.hrl").

with_metrics(Fun) ->
    case whereis(erl_bridge_metrics) of
        undefined ->
            {ok, Pid} = erl_bridge_metrics:start_link(),
            try Fun()
            after
                unlink(Pid),
                exit(Pid, kill)
            end;
        _AlreadyRunning ->
            Fun()
    end.

%% Metric updates are casts, so a read has to drain the mailbox before
%% asserting. Without this, an assertion can race the update it is
%% checking and fail intermittently.
sync() ->
    _ = erl_bridge_metrics:describe(),
    timer:sleep(50),
    ok.

%%%===================================================================
%%% Registration
%%%===================================================================

%% Every declared metric must exist at zero before anything touches it.
%% Prometheus reads a missing series as "no data" rather than zero, so a
%% rate() spanning the first scrape would return nothing.
preseeded_test() ->
    with_metrics(fun() ->
        lists:foreach(
          fun({Name, _Type}) ->
                  ?assertEqual(0, erl_bridge_metrics:value(Name),
                               lists:flatten(
                                 io_lib:format("~p not preseeded", [Name])))
          end, ?METRICS)
    end).

%%%===================================================================
%%% Counters and gauges
%%%===================================================================

counter_accumulates_test() ->
    with_metrics(fun() ->
        Before = erl_bridge_metrics:value(requests_ok),
        erl_bridge_metrics:counter(requests_ok, 1),
        erl_bridge_metrics:counter(requests_ok, 2),
        sync(),
        ?assertEqual(Before + 3, erl_bridge_metrics:value(requests_ok))
    end).

%% A gauge may fall; a counter may not. Adjusting connections_active down
%% on disconnect is the whole reason there are two kinds.
gauge_adjusts_both_ways_test() ->
    with_metrics(fun() ->
        erl_bridge_metrics:adjust(connections_active, 5),
        erl_bridge_metrics:adjust(connections_active, -2),
        sync(),
        ?assertEqual(3, erl_bridge_metrics:value(connections_active))
    end).

gauge_sets_absolute_test() ->
    with_metrics(fun() ->
        erl_bridge_metrics:gauge(connections_active, 42),
        sync(),
        ?assertEqual(42, erl_bridge_metrics:value(connections_active))
    end).

%% ets:update_counter truncates toward zero; a fractional gauge must not
%% reach Prometheus as an integer it never really was.
gauge_truncates_test() ->
    with_metrics(fun() ->
        erl_bridge_metrics:gauge(connections_active, 3.9),
        sync(),
        ?assertEqual(3, erl_bridge_metrics:value(connections_active))
    end).

%%%===================================================================
%%% Prometheus exposition
%%%===================================================================

%% The shape Prometheus actually requires. A malformed name or a missing
%% TYPE line makes the scrape fail wholesale, so both are asserted
%% explicitly rather than eyeballed.
exposition_format_test() ->
    with_metrics(fun() ->
        erl_bridge_metrics:counter(requests_ok, 7),
        sync(),
        Body = binary_to_list(erl_bridge_metrics:scrape()),
        ?assertNotEqual(nomatch, string:find(Body, "# HELP erl_bridge_requests_ok_total")),
        ?assertNotEqual(nomatch, string:find(Body, "# TYPE erl_bridge_requests_ok_total counter")),
        ?assertNotEqual(nomatch, string:find(Body, "\nerl_bridge_requests_ok_total 7\n"))
    end).

%% Counters carry the _total suffix; gauges must not.
exposition_suffix_test() ->
    with_metrics(fun() ->
        erl_bridge_metrics:gauge(connections_active, 2),
        sync(),
        Body = binary_to_list(erl_bridge_metrics:scrape()),
        ?assertNotEqual(nomatch, string:find(Body, "# TYPE erl_bridge_connections_active gauge")),
        ?assertEqual(nomatch, string:find(Body, "erl_bridge_connections_active_total")),
        ?assertEqual(nomatch, string:find(Body, "erl_bridge_connections_active_total "))
    end).

%% Every rendered line must match the Prometheus exposition grammar: a
%% comment, or `NAME VALUE'. An invalid name does not drop one series, it
%% makes Prometheus reject the entire scrape -- which is why
%% sanitisation exists at all.
exposition_names_are_valid_test() ->
    with_metrics(fun() ->
        erl_bridge_metrics:counter(requests_ok, 1),
        erl_bridge_metrics:gauge(connections_active, 2),
        sync(),
        Body = binary_to_list(erl_bridge_metrics:scrape()),
        Bad = [Line || Line <- string:split(Body, "\n", all),
                       not is_valid_line(Line)],
        ?assertEqual([], Bad)
    end).

is_valid_line("") -> true;
is_valid_line([$# | _]) -> true;
is_valid_line(Line) ->
    case string:split(Line, " ") of
        [Name, Value] ->
            %% string:to_integer/1 returns {Integer, Rest}, so success is
            %% a tuple -- not an integer.
            is_valid_metric_name(Name) andalso is_tuple(string:to_integer(Value));
        _ ->
            false
    end.

is_valid_metric_name([First | Rest]) ->
    is_name_start(First) andalso lists:all(fun is_name_char/1, Rest);
is_valid_metric_name(_) ->
    false.

is_name_start(C) ->
    (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse
        C =:= $_ orelse C =:= $:.

is_name_char(C) -> is_name_start(C) orelse (C >= $0 andalso C =< $9).
