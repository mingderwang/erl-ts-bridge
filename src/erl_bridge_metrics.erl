%%%-------------------------------------------------------------------
%%% @doc Metrics: a registry of counters and gauges plus a Prometheus
%%% text exposition renderer.
%%%
%%% <b>Why not `telemetry_metrics_prometheus_core'?</b> Every release of
%%% `telemetry_metrics' is published as a mix project with no
%%% `rebar.config', so depending on it forces Elixir/mix into a build
%%% that is otherwise pure Erlang. The exposition format is a short,
%%% stable specification, and implementing it here keeps the toolchain
%%% honest.
%%%
%%% <b>What is deliberately not reimplemented</b> is the instrumentation
%%% API. This module emits ordinary {@link telemetry:execute/3} events
%%% under `erl_bridge.*', so any other backend -- including
%%% `telemetry_metrics_prometheus_core', or a reporter forwarding to
%%% OpenTelemetry -- can be attached in `erl_bridge_app:start/2' without
%%% changing a single call site.
%%%
%%% State lives in a public ETS table, not in the gen_server state.
%%% That matters for two reasons: updates become lock-free atomic
%%% operations instead of messages, and a scrape reads the table
%%% directly instead of queueing behind every update. The gen_server
%%% exists only to own the table's lifetime.
%%% @end
%%%-------------------------------------------------------------------
-module(erl_bridge_metrics).

-behaviour(gen_server).

-include("erl_bridge.hrl").

-export([start_link/0, scrape/0, counter/2, adjust/2, gauge/2, value/1,
         describe/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(TABLE, ?MODULE).

-type metric_name() :: atom().

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Add `Delta' to a counter.
%%
%% Rendered with a `_total' suffix, per the Prometheus convention for
%% counters. Never decreases.
-spec counter(metric_name(), integer()) -> ok.
counter(Name, Delta) ->
    gen_server:cast(?SERVER, {counter, Name, Delta}).

%% @doc Add `Delta' to a gauge.
%%
%% For quantities that go up and down -- currently the number of live
%% connections. Atomic, so concurrent workers cannot lose an update the
%% way a read-modify-write in the gen_server state would.
-spec adjust(metric_name(), integer()) -> ok.
adjust(Name, Delta) ->
    gen_server:cast(?SERVER, {adjust, Name, Delta}).

%% @doc Set a gauge to an absolute value.
-spec gauge(metric_name(), number()) -> ok.
gauge(Name, Value) ->
    gen_server:cast(?SERVER, {gauge, Name, Value}).

%% @doc Read one metric synchronously. For tests and diagnostics.
-spec value(metric_name()) -> integer() | undefined.
value(Name) ->
    try ets:lookup(?TABLE, Name) of
        [{_, V, _}] -> V;
        [] -> undefined
    catch error:badarg -> undefined
    end.

%% @doc Every metric with its value, for tests and diagnostics.
-spec describe() -> [{atom(), integer(), counter | gauge}].
describe() ->
    lists:sort(ets:tab2list(?TABLE)).

%% @doc The current metrics in Prometheus text exposition format.
%%
%% Reads the ETS table directly, so a slow scrape cannot be serialised
%% behind metric updates.
-spec scrape() -> binary().
scrape() ->
    iolist_to_binary(lists:flatmap(fun render/1, describe())).

%%%===================================================================
%%% gen_server
%%%===================================================================

init([]) ->
    process_flag(trap_exit, true),
    %% Created before anything is seeded: ensure/3 calls ets:member/2,
    %% which raises badarg rather than returning false when the table does
    %% not exist yet.
    Table = ets:new(?TABLE, [set, public, named_table,
                             {write_concurrency, true}]),
    %% Pre-seeded at zero. A counter that only appears once it is first
    %% incremented cannot be used with rate() or increase(): Prometheus
    %% reads a missing series as "no data", not as zero, so a query
    %% spanning the first scrape returns nothing.
    lists:foreach(fun({Name, Type}) -> ensure(Name, 0, Type) end, ?METRICS),
    {ok, #{table => Table}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({counter, Name, Delta}, State) ->
    ensure(Name, 0, counter),
    ets:update_counter(?TABLE, Name, {2, Delta}, {Name, 0, counter}),
    {noreply, State};
handle_cast({adjust, Name, Delta}, State) ->
    ensure(Name, 0, gauge),
    ets:update_counter(?TABLE, Name, {2, Delta}, {Name, 0, gauge}),
    {noreply, State};
handle_cast({gauge, Name, Value}, State) ->
    ensure(Name, 0, gauge),
    ets:insert(?TABLE, {Name, trunc(Value), gauge}),
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal
%%%===================================================================

ensure(Name, Value, Type) ->
    case ets:member(?TABLE, Name) of
        true -> ok;
        false -> ets:insert(?TABLE, {Name, Value, Type})
    end.

%% Prometheus text exposition format:
%% https://prometheus.io/docs/instrumenting/exposition_formats/
%%
%% Metric names must match [a-zA-Z_:][a-zA-Z0-9_:]*. An Erlang atom
%% containing a dash is therefore translated rather than emitted raw --
%% an invalid name makes Prometheus reject the whole scrape, not just
%% that one series.
render({Name, Value, Type}) ->
    Base = lists:flatten(io_lib:format("erl_bridge_~s", [sanitise(Name)])),
    Metric = case Type of
                 counter -> Base ++ "_total";
                 gauge -> Base
             end,
    Help = lists:flatten(
             io_lib:format("erl_bridge ~s (generated)", [Name])),
    ["# HELP ", Metric, " ", Help, "\n",
     "# TYPE ", Metric, " ", atom_to_list(Type), "\n",
     Metric, " ", integer_to_list(Value), "\n"].

sanitise(Name) ->
    lists:flatmap(fun character_to_text/1, atom_to_list(Name)).

character_to_text(C) when C >= $a, C =< $z -> [C];
character_to_text(C) when C >= $A, C =< $Z -> [C];
character_to_text(C) when C >= $0, C =< $9 -> [C];
character_to_text($_) -> "_";
character_to_text(_) -> "_".
