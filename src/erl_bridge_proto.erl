%%%-------------------------------------------------------------------
%%% @doc Wire protocol v2: pure encoding and decoding.
%%%
%%% Every function here is side-effect free and total: it either returns
%%% a well-formed term or an `{error, Reason}' describing precisely what
%%% was wrong with the input. Nothing in this module touches a socket,
%%% a process dictionary or the clock, which is what makes the framing
%%% and version rules testable without standing up a server.
%%%
%%% All multi-byte integers are big-endian. Frames carry a 4-byte
%%% unsigned length prefix, added and removed by `{packet, 4}' on the
%%% socket, so this module only ever sees payloads.
%%%
%%% See PROTOCOL.md for the normative description.
%%% @end
%%%-------------------------------------------------------------------
-module(erl_bridge_proto).

-include("erl_bridge.hrl").

-export([decode_hello/1, encode_hello_ack/2,
         decode_request/1, encode_response/3,
         supported_version/0, is_supported_version/1,
         add/2, add_result/2, max_request_bytes/0]).

-export_type([request/0, response_status/0, hello_error/0]).

-type request() :: #{id := non_neg_integer(),
                     opcode := non_neg_integer(),
                     a := integer(),
                     b := integer()}.
-type response_status() :: 0 | 1.

%% Status in a HELLO_ACK: a separate three-valued set, because a client
%% that cannot authenticate and a client speaking the wrong protocol need
%% different remedies. Folding these into response_status/0 would make
%% ?HELLO_AUTH_FAILED a type-contract violation -- which dialyzer rightly
%% flagged.
-type hello_status() :: 0 | 1 | 2.

-type hello_error() :: malformed | token_too_large.

%%%===================================================================
%%% Version negotiation
%%%===================================================================

%% @doc The single protocol version this build speaks.
%%
%% Version 1 was unauthenticated and had no handshake, so accepting it
%% would be an authentication bypass. This is therefore a hard floor
%% rather than a capability list.
-spec supported_version() -> pos_integer().
supported_version() ->
    ?PROTO_VERSION_MAX.

-spec is_supported_version(integer()) -> boolean().
is_supported_version(V) ->
    V >= ?PROTO_VERSION_MIN andalso V =< ?PROTO_VERSION_MAX.

%%%===================================================================
%%% HELLO / HELLO_ACK
%%%===================================================================

%% @doc Decode a HELLO frame: `<<Version:8, TokenLen:16, Token/binary>>'.
%%
%% Returns `{ok, #{version => V, token => Bin}}'. The announced
%% `TokenLen' is cross-checked against the real payload size rather than
%% trusted, so a peer cannot desynchronise our reader by announcing one
%% length and sending another.
%%
%% An empty token decodes successfully on purpose: whether a token is
%% required is an authentication question, and answering it here would
%% conflate "no credential presented" with "no credential configured".
-spec decode_hello(binary()) -> {ok, map()} | {error, hello_error()}.
decode_hello(<<Version:8, Len:16/unsigned-big, Token/binary>>) ->
    Actual = byte_size(Token),
    case Actual > ?MAX_TOKEN_BYTES of
        true ->
            %% Checked before the length cross-check so an oversized
            %% token is distinguishable from a merely inconsistent one.
            {error, token_too_large};
        false when Len =/= Actual ->
            {error, malformed};
        false ->
            {ok, #{version => Version, token => Token}}
    end;
decode_hello(_) ->
    {error, malformed}.

%% @doc Encode the server's reply to a HELLO.
%%
%% `Version' is echoed only on success. On failure it is zero, so a
%% rejected client learns nothing about the supported range beyond what
%% it already guessed.
-spec encode_hello_ack(non_neg_integer(), hello_status()) -> binary().
encode_hello_ack(Version, Status) ->
    <<Version:8, Status:8>>.

%%%===================================================================
%%% Request / response
%%%===================================================================

%% @doc Decode a 21-byte request payload.
%%
%% The opcode is returned unvalidated: an unknown opcode is a protocol
%% error the connection layer reports, not a decode error, because the
%% frame itself was well formed.
-spec decode_request(binary()) -> {ok, request()} | {error, term()}.
decode_request(<<Id:32/unsigned-big, Opcode:8, A:64/signed-big,
                 B:64/signed-big>>) ->
    {ok, #{id => Id, opcode => Opcode, a => A, b => B}};
decode_request(Payload) ->
    {error, {bad_request_size, byte_size(Payload)}}.

%% @doc Encode a 13-byte response payload.
-spec encode_response(non_neg_integer(), response_status(), integer()) ->
                             binary().
encode_response(Id, Status, Result) ->
    <<Id:32/unsigned-big, Status:8, Result:64/signed-big>>.

%% @doc The largest possible request payload. Used to enforce a floor on
%% `max_frame_size' and to size receive buffers.
-spec max_request_bytes() -> pos_integer().
max_request_bytes() ->
    4 + 1 + 8 + 8.

%%%===================================================================
%%% Arithmetic
%%%===================================================================

%% @doc Compute `A + B', reporting overflow rather than wrapping.
%%
%% Erlang has bignums, so `A + B' cannot overflow: it silently produces
%% an integer that does not fit the 64-bit response field. Without this
%% check the encoder would truncate it and the client would read a
%% confidently wrong number. This is the single most important function
%% in the module for correctness.
-spec add(integer(), integer()) -> {ok, integer()} | overflow.
add(A, B) ->
    case fits_int64(A + B) of
        true -> {ok, A + B};
        false -> overflow
    end.

%% @doc As {@link add/2}, but in the shape the connection layer wants:
%% `{ok, {Status, Result}}'. Success yields `Status = 0'; overflow
%% yields `Status = 1' with a zero result.
-spec add_result(integer(), integer()) -> {ok, {0, integer()} | {1, 0}}.
add_result(A, B) ->
    case add(A, B) of
        {ok, Sum} -> {ok, {0, Sum}};
        overflow -> {ok, {1, 0}}
    end.

-spec fits_int64(integer()) -> boolean().
fits_int64(N) ->
    N >= -9223372036854775808 andalso
        N =< 9223372036854775807.
