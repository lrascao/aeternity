%%%-------------------------------------------------------------------
%%% @copyright (C) 2018, Aeternity Anstalt
%%% @doc CT test suite for AEVM/chain interface
%%% @end
%%%-------------------------------------------------------------------
-module(aevm_chain_SUITE).

%% common_test exports
-export([ all/0
        , groups/0
        , init_per_suite/1
        ]).

%% test case exports
-export([ height/1
        , contracts/1
        , spend/1
        ]).

-include_lib("common_test/include/ct.hrl").
-include_lib("aecore/include/blocks.hrl").
-include_lib("aecontract/include/aecontract.hrl").
-include_lib("aecontract/include/hard_forks.hrl").

-define(BENEFICIARY_PUBKEY, <<12345:?BENEFICIARY_PUB_BYTES/unit:8>>).
-define(BOGUS_PREV_HASH, <<0:?BLOCK_HEADER_HASH_BYTES/unit:8>>).

%%%===================================================================
%%% Common test framework
%%%===================================================================

all() ->
    [{group, all_tests}
    ].

groups() ->
    [ {all_tests, [sequence],
        [ {group, height}
        , {group, spend}
        , {group, contracts}
        ]}
    , {height, [sequence],
        [ height ]}
    , {spend, [sequence],
        [ spend ]}
    , {contracts, [sequence],
        [ contracts ]}
    ].

init_per_suite(Config) ->
    case aect_test_utils:latest_protocol_version() < ?IRIS_PROTOCOL_VSN of
        true -> Config;
        false -> {skip, aevm_deprecated}
    end.

%%%===================================================================
%%% Setup
%%%===================================================================

%% Uses aect_test_utils to set up the chain, but after the setup everything is
%% done through the aevm_chain_api.
setup_chain() ->
    S0              = aect_test_utils:new_state(),
    {Account1, S1}  = aect_test_utils:setup_new_account(S0),
    {Account2, S2}  = aect_test_utils:setup_new_account(S1),
    {Contract1, S3} = create_contract(Account1, S2),
    {Contract2, S4} = create_contract(Account2, S3),
    Trees = aect_test_utils:trees(S4),
    Height = 1,
    Vsn = aec_hard_forks:protocol_effective_at_height(Height),
    TxEnv = aetx_env:contract_env(Height, Vsn,
                                  aeu_time:now_in_msecs(),
                                  ?BENEFICIARY_PUBKEY, _Difficulty = 0,
                                  ?BOGUS_PREV_HASH
                                 ),
    VM = aect_test_utils:latest_sophia_vm_version(),
    InitS = aec_vm_chain:new_state(Trees, TxEnv, Contract1, VM),
    {[Account1, Account2, Contract1, Contract2], InitS}.

create_contract(Owner, S) ->
    OwnerPrivKey = aect_test_utils:priv_key(Owner, S),
    {ok, IdSource} = aect_test_utils:read_contract(identity),
    {ok, IdContract} = aect_test_utils:compile_contract(identity),
    {ok, CallData} = aect_test_utils:encode_call_data(IdSource, <<"init">>, []),

    Overrides    = #{ code => IdContract
                    , call_data => CallData
                    , gas => 10000
                    , amount => 2000},
    CreateTx     = aect_test_utils:create_tx(Owner, Overrides, S),
    {SignedTx, [SignedTx], S1} =
        sign_and_apply_transaction(CreateTx, OwnerPrivKey, S),
    {aect_contracts:compute_contract_pubkey(Owner, aetx:nonce(CreateTx)), S1}.

sign_and_apply_transaction(Tx, PrivKey, S1) ->
    SignedTx = aec_test_utils:sign_tx(Tx, PrivKey),
    Trees    = aect_test_utils:trees(S1),
    Height   = 1,
    Env      = aetx_env:tx_env(Height),
    {ok, AcceptedTxs, Trees1, _} =
        aec_block_micro_candidate:apply_block_txs([SignedTx], Trees, Env),
    S2       = aect_test_utils:set_trees(Trees1, S1),
    {SignedTx, AcceptedTxs, S2}.

call_data(Arg) ->
    {ok, Source} = aect_test_utils:read_contract(identity),
    {ok, CallData} = aect_test_utils:encode_call_data(Source, <<"main">>, [Arg]),
    CallData.

%%%===================================================================
%%% Height tests
%%%===================================================================

height(_Cfg) ->
    {_, S} = setup_chain(),
    1 = aec_vm_chain:get_height(S),
    ok.

%%%===================================================================
%%% Spend tests
%%%===================================================================

spend(_Cfg) ->
    {[Acc, _Acc2, Contract1, _Contract2], S} = setup_chain(),
    AccId    = aeser_id:create(account, Acc),
    AccBal1  = aec_vm_chain:get_balance(Acc, S),
    Bal1     = aec_vm_chain:get_balance(Contract1, S),
    Amount   = 50,
    {ok, T1} = aec_vm_chain:spend_tx(AccId, Amount, S),
    {ok, S1} = aec_vm_chain:spend(T1, S),
    Bal2     = aec_vm_chain:get_balance(Contract1, S1),
    Bal2     = Bal1 - Amount,
    AccBal2  = aec_vm_chain:get_balance(Acc, S1),
    AccBal2  = AccBal1 + Amount,
    {ok, T2} = aec_vm_chain:spend_tx(AccId, 1000000, S1),
    {error, insufficient_funds} = aec_vm_chain:spend(T2, S1),
    ok.

%%%===================================================================
%%% Contract tests
%%%===================================================================

contracts(_Cfg) ->
    {[_Acc, _Acc2, Contract1, Contract2], S} = setup_chain(),
    _S1 = lists:foldl(fun({Value, Arg}, S0) -> make_call(Contract1, Contract2, Value, Arg, S0) end,
                      S, [{(I - 1) * 100, I + 100} || I <- lists:seq(1, 10)]),
    ok.

make_call(From, To, Value, Arg, S) ->
    C1Bal1    = aec_vm_chain:get_balance(From, S),
    C2Bal1    = aec_vm_chain:get_balance(To, S),
    CallData  = call_data(integer_to_binary(Arg)),
    Gas       = 10000,
    CallStack = [],
    Origin    = From,
    {CallRes, S1} = aec_vm_chain:call_contract(To, Gas, Value, CallData, CallStack, Origin, S),
    case C1Bal1 >= Value of
        _ when Value < 0 ->
            {exception, unknown_error} = aevm_chain_api:return_value(CallRes),
            S;
        true ->
            GasUsed  = aevm_chain_api:gas_spent(CallRes),
            {ok, <<Arg:256>>} = aevm_chain_api:return_value(CallRes),
            true     = GasUsed > 0,
            true     = GasUsed =< Gas,
            C1Bal2   = aec_vm_chain:get_balance(From, S1),
            C1Bal2   = C1Bal1 - Value,
            C2Bal2   = aec_vm_chain:get_balance(To, S1),
            C2Bal2   = C2Bal1 + Value,
            S1;
        false ->
            {exception, unknown_error} = aevm_chain_api:return_value(CallRes),
            S
    end.
