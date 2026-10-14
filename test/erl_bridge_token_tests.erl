%%%-------------------------------------------------------------------
%%% @doc Tests for token verification and generation.
%%%
%%% The property under test is not "does it reject the wrong token" but
%%% "does it reject it without leaking how much of it was right" --
%%% except that timing is not assertable from EUnit. What is assertable
%%% is that the comparison is actually `crypto:hash_equals/2' and that
%%% every edge case behaves, including the length-mismatch path that
%%% `crypto:hash_equals/2' raises `badarg' on.
%%% @end
%%%-------------------------------------------------------------------
-module(erl_bridge_token_tests).

-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% Matching tokens
%%%===================================================================

exact_match_test() ->
    ?assert(erl_bridge_token:verify(<<"s3cret">>, <<"s3cret">>)).

wrong_token_test() ->
    ?assertNot(erl_bridge_token:verify(<<"s3cret">>, <<"s3cres">>)),
    ?assertNot(erl_bridge_token:verify(<<"s3cret">>, <<"s3crev">>)),
    ?assertNot(erl_bridge_token:verify(<<"s3cret">>, <<"S3cret">>)).

%% A one-byte difference in the first byte must still be rejected -- the
%% case a short-circuiting comparison is fastest at leaking.
differs_in_first_byte_test() ->
    ?assertNot(erl_bridge_token:verify(<<"aaaaaa">>, <<"baaaaa">>)),
    ?assertNot(erl_bridge_token:verify(<<"aaaaaa">>, <<"aaaaab">>)).

%% crypto:hash_equals/2 raises badarg on a length mismatch. If this test
%% ever starts failing with an exception rather than `false', the length
%% guard has been lost.
length_mismatch_test() ->
    ?assertNot(erl_bridge_token:verify(<<"abc">>, <<"abcd">>)),
    ?assertNot(erl_bridge_token:verify(<<"abcd">>, <<"abc">>)),
    ?assertNot(erl_bridge_token:verify(<<>>, <<"a">>)).

empty_tokens_match_test() ->
    ?assert(erl_bridge_token:verify(<<>>, <<>>)).

long_token_test() ->
    Token = binary:copy(<<"ab">>, 128),
    ?assert(erl_bridge_token:verify(Token, Token)),
    ?assertNot(erl_bridge_token:verify(Token, <<0:2048>>)).

%%%===================================================================
%%% Absent credentials
%%%===================================================================

%% No token configured: every peer is trusted, whether or not it presents
%% something. Rejecting a peer that *does* present a token would turn down
%% a correctly configured client because the operator has not finished
%% securing the server yet.
auth_disabled_test() ->
    ?assert(erl_bridge_token:verify(undefined, undefined)),
    ?assert(erl_bridge_token:verify(undefined, <<>>)),
    ?assert(erl_bridge_token:verify(undefined, <<"anything">>)).

%% Configured but absent: rejected.
missing_token_rejected_test() ->
    ?assertNot(erl_bridge_token:verify(<<"secret">>, undefined)),
    ?assertNot(erl_bridge_token:verify(<<"secret">>, <<>>)).

%%%===================================================================
%%% Generation
%%%===================================================================

generate_test() ->
    {ok, Token} = erl_bridge_token:generate(32),
    %% 32 random bytes, hex encoded.
    ?assertEqual(64, byte_size(Token)),
    ?assertEqual(nomatch, string:find(Token, "-")).

%% Two invocations must not collide; a constant "random" token would be a
%% catastrophic authentication failure that looks fine in testing.
generate_is_random_test() ->
    {ok, A} = erl_bridge_token:generate(32),
    {ok, B} = erl_bridge_token:generate(32),
    ?assertNotEqual(A, B).

%% Anything under 128 bits of entropy is refused rather than accepted.
generate_rejects_short_test() ->
    ?assertMatch({error, {token_bytes_too_small, 4}},
                 erl_bridge_token:generate(4)),
    ?assertMatch({error, {token_bytes_too_small, _}},
                 erl_bridge_token:generate(0)).

%% A generated token must verify against itself, or the happy path is
%% broken for reasons unrelated to auth.
generated_token_verifies_test() ->
    {ok, Token} = erl_bridge_token:generate(32),
    ?assert(erl_bridge_token:verify(Token, Token)),
    ?assertNot(erl_bridge_token:verify(Token, <<"wrong">>)).
