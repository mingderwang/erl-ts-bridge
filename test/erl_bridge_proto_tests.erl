%%%-------------------------------------------------------------------
%%% @doc Unit tests for the pure protocol layer.
%%%
%%% These need no sockets and no running server: everything in
%%% {@link erl_bridge_proto} is a total function, which is the main
%%% reason the wire format was kept out of the connection processes.
%%% @end
%%%-------------------------------------------------------------------
-module(erl_bridge_proto_tests).

-include_lib("eunit/include/eunit.hrl").

-include("erl_bridge.hrl").

-define(V2, ?PROTO_VERSION_MAX).

%%%===================================================================
%%% Version negotiation
%%%===================================================================

supported_version_test() ->
    ?assertEqual(?V2, erl_bridge_proto:supported_version()).

%% Only the current version is accepted. v1 was unauthenticated, so
%% accepting it would be an authentication bypass.
version_bounds_test() ->
    ?assertNot(erl_bridge_proto:is_supported_version(1)),
    ?assertNot(erl_bridge_proto:is_supported_version(0)),
    ?assertNot(erl_bridge_proto:is_supported_version(?V2 + 1)),
    ?assertNot(erl_bridge_proto:is_supported_version(255)),
    ?assert(erl_bridge_proto:is_supported_version(?V2)).

%%%===================================================================
%%% HELLO
%%%===================================================================

hello_roundtrip_test() ->
    Token = <<"s3cret-token">>,
    Frame = <<?V2:8, (byte_size(Token)):16/unsigned-big, Token/binary>>,
    ?assertEqual({ok, #{version => ?V2, token => Token}},
                 erl_bridge_proto:decode_hello(Frame)).

%% An empty token must decode. Whether one is *required* is an auth
%% question, and conflating the two would make "no token configured" and
%% "no token presented" indistinguishable.
hello_empty_token_decodes_test() ->
    ?assertEqual({ok, #{version => ?V2, token => <<>>}},
                 erl_bridge_proto:decode_hello(<<?V2:8, 0:16/unsigned-big>>)).

%% The announced length must match the payload. Trusting it would let a
%% peer desynchronise the reader.
hello_length_mismatch_test() ->
    ?assertEqual({error, malformed},
                 erl_bridge_proto:decode_hello(<<?V2:8, 99:16/unsigned-big,
                                                    "short">>)).

hello_too_short_test() ->
    ?assertEqual({error, malformed}, erl_bridge_proto:decode_hello(<<>>)),
    ?assertEqual({error, malformed}, erl_bridge_proto:decode_hello(<<1, 2>>)),
    ?assertEqual({error, malformed}, erl_bridge_proto:decode_hello(<<?V2:8>>)).

%% An oversized token is refused rather than buffered. Without a bound a
%% peer could make us hold an arbitrarily large frame in memory.
hello_token_too_large_test() ->
    %% binary:copy rather than `<<0:(?MAX_TOKEN_BYTES + 1 * 8)>>': `*'
    %% binds tighter, so that expression is 520 bits (65 bytes) -- under
    %% the limit, and the test would pass for the wrong reason.
    Huge = binary:copy(<<0>>, ?MAX_TOKEN_BYTES + 1),
    Frame = <<?V2:8, (byte_size(Huge)):16/unsigned-big, Huge/binary>>,
    ?assertEqual({error, token_too_large},
                 erl_bridge_proto:decode_hello(Frame)).

hello_max_token_accepted_test() ->
    Token = binary:copy(<<"a">>, ?MAX_TOKEN_BYTES),
    Frame = <<?V2:8, (?MAX_TOKEN_BYTES):16/unsigned-big, Token/binary>>,
    ?assertMatch({ok, #{token := _}}, erl_bridge_proto:decode_hello(Frame)).

%% On rejection the version is zeroed, so a refused client learns nothing
%% about the supported range beyond what it already guessed.
hello_ack_test() ->
    ?assertEqual(<<?V2:8, ?HELLO_OK:8>>,
                 erl_bridge_proto:encode_hello_ack(?V2, ?HELLO_OK)),
    ?assertEqual(<<0:8, ?HELLO_BAD_VERSION:8>>,
                 erl_bridge_proto:encode_hello_ack(0, ?HELLO_BAD_VERSION)),
    ?assertEqual(<<0:8, ?HELLO_AUTH_FAILED:8>>,
                 erl_bridge_proto:encode_hello_ack(0, ?HELLO_AUTH_FAILED)).

%%%===================================================================
%%% Request / response framing
%%%===================================================================

request_roundtrip_test() ->
    Payload = <<7:32/unsigned-big, ?OP_ADD:8,
                10:64/signed-big, (-20):64/signed-big>>,
    ?assertEqual(#{id => 7, opcode => ?OP_ADD, a => 10, b => -20},
                 element(2, erl_bridge_proto:decode_request(Payload))).

request_size_test() ->
    ?assertEqual(21, erl_bridge_proto:max_request_bytes()),
    ?assertEqual(21, byte_size(<<0:32/unsigned-big, 0:8, 0:64/signed-big,
                                0:64/signed-big>>)).

%% Wrong sizes are rejected with the actual size, which makes a broken
%% client debuggable from the log alone.
request_bad_size_test() ->
    ?assertEqual({error, {bad_request_size, 0}},
                 erl_bridge_proto:decode_request(<<>>)),
    ?assertEqual({error, {bad_request_size, 20}},
                 erl_bridge_proto:decode_request(binary:copy(<<0>>, 20))),
    ?assertEqual({error, {bad_request_size, 22}},
                 erl_bridge_proto:decode_request(binary:copy(<<0>>, 22))).

response_roundtrip_test() ->
    Reply = erl_bridge_proto:encode_response(9, 0, 30),
    ?assertEqual(13, byte_size(Reply)),
    ?assertMatch(<<9:32/unsigned-big, 0:8, 30:64/signed-big>>, Reply).

%%%===================================================================
%%% Arithmetic and the 64-bit boundary
%%%===================================================================

arithmetic_test() ->
    ?assertEqual({ok, {0, 30}}, erl_bridge_proto:add_result(10, 20)),
    ?assertEqual({ok, {0, 5}}, erl_bridge_proto:add_result(-2, 7)),
    ?assertEqual({ok, {0, 0}}, erl_bridge_proto:add_result(0, 0)),
    ?assertEqual({ok, {0, 9000000001}},
                 erl_bridge_proto:add_result(9000000000, 1)).

%% The extremes themselves are representable and must succeed. Only a sum
%% that leaves the range is an error.
boundary_values_test() ->
    Max = 9223372036854775807,
    Min = -9223372036854775808,
    ?assertEqual({ok, {0, Max}}, erl_bridge_proto:add_result(Max - 1, 1)),
    ?assertEqual({ok, {0, Min}}, erl_bridge_proto:add_result(Min + 1, -1)),
    ?assertEqual({ok, {1, 0}}, erl_bridge_proto:add_result(Max, 1)),
    ?assertEqual({ok, {1, 0}}, erl_bridge_proto:add_result(Min, -1)),
    ?assertEqual({ok, {1, 0}}, erl_bridge_proto:add_result(Max, Max)).

%% The regression this guards: Erlang bignums make Max + 1 a perfectly
%% good integer, and encoding it would silently truncate into a 64-bit
%% field, producing a confidently wrong answer.
overflow_does_not_truncate_test() ->
    Max = 9223372036854775807,
    {ok, {Status, Result}} = erl_bridge_proto:add_result(Max, 1),
    ?assertEqual(1, Status),
    ?assertEqual(0, Result).
