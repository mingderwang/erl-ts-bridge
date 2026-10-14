%%%-------------------------------------------------------------------
%%% @doc Constant-time secret comparison for the HELLO token.
%%%
%%% Naive equality (`A =:= B') short-circuits on the first differing
%%% byte, so the time taken to reject a guess leaks how many leading
%%% bytes were right. Over a network that is a slow oracle, but it is a
%%% real one.
%%%
%%% OTP provides the primitive in `crypto:hash_equals/2', which is what
%%% this uses. It is written down here, in one place, as a named
%%% function with a comment, rather than inlined -- so that nobody later
%%% "simplifies" it back to `=:=' and the timing property survives the
%%% refactor.
%%%
%%% <b>On the length check.</b> `crypto:hash_equals/2' raises `badarg'
%%% when its arguments differ in length, so the lengths must be compared
%%% first. That comparison short-circuits, and therefore leaks the token
%%% length. That is deliberate and standard: a fixed-length token would
%%% leak far more, and the length of a credential is not the secret.
%%% @end
%%%-------------------------------------------------------------------
-module(erl_bridge_token).

-export([verify/2, generate/1]).

%% @doc Verify a presented token against the configured secret.
%%
%% Returns `true' only on an exact byte-for-byte match, except when
%% authentication is disabled -- see the first clause of verify/2.
-spec verify(binary() | undefined, binary() | undefined) -> boolean().
verify(undefined, _Presented) ->
    %% Authentication is not configured. Every peer is already trusted, so
    %% a token presented by one must NOT cause a rejection: that would
    %% turn down a correctly configured client because the operator has
    %% not finished securing the server yet, which is a confusing way to
    %% fail. The caller logs a warning in this case -- the decision
    %% belongs with the connection layer, which knows the peer context.
    true;
verify(_Configured, undefined) ->
    %% A token is required but the client presented none.
    false;
verify(Configured, Presented) when is_binary(Configured),
                                 is_binary(Presented) ->
    byte_size(Configured) =:= byte_size(Presented)
        andalso crypto:hash_equals(Configured, Presented).

%% @doc Generate a random token, hex-encoded.
%%
%% Exists so the README can show a one-liner for producing a real secret,
%% rather than leaving room for `crypto:hash(sha256, "password")', which
%% is guessable and looks safe.
-spec generate(pos_integer()) -> {ok, binary()} | {error, term()}.
generate(Bytes) when is_integer(Bytes), Bytes >= 16 ->
    %% crypto:strong_rand_bytes/1 returns a binary or raises; it never
    %% returns an error tuple. The {error, _} clause that used to sit here
    %% was dead code, which dialyzer pointed out.
    {ok, hex(crypto:strong_rand_bytes(Bytes))};
generate(Bytes) ->
    {error, {token_bytes_too_small, Bytes}}.

%%%===================================================================
%%% Internal
%%%===================================================================

%% One hex character per nibble. N is already in 0..15, so it is used
%% directly -- dividing it by 16 again would emit two characters per
%% nibble and double the length of every generated token.
hex(Bin) ->
    <<<<(hex_digit(N))>> || <<N:4>> <= Bin>>.

hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $a + N - 10.
