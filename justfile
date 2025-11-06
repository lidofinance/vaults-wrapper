set dotenv-load := true
set unstable := true

fusaka_tx_gas_limit := '16777216'
verify_flags := if env('PUBLISH_SOURCES', '') != '' {
  '--verify --verifier etherscan --retries 10 --delay 10'
} else {
  ''
}
common_script_flags := "--rpc-url " + env('RPC_URL') + " --broadcast --sender " + env('DEPLOYER') + " --private-key " + env('PRIVATE_KEY') + " --enable-tx-gas-limit --slow " + verify_flags + " --non-interactive"

default:
  @just --list

deploy-factory:
  forge script script/DeployFactory.s.sol:DeployFactory \
    {{common_script_flags}} \
    --sig 'run()'

deploy-pool FACTORY_ADDRESS POOL_PARAMS_JSON:
  POOL_PARAMS_JSON={{POOL_PARAMS_JSON}} \
  FACTORY_ADDRESS={{FACTORY_ADDRESS}} \
  forge script script/DeployPool.s.sol:DeployWrapper \
    {{common_script_flags}} \
    --gas-limit {{fusaka_tx_gas_limit}} \
    --sig 'run()'

deploy-ggv-mocks:
  STETH={{env('STETH')}} \
  WSTETH={{env('WSTETH')}} \
  forge script script/DeployGGVMocks.s.sol:DeployGGVMocks \
    {{common_script_flags}} \
    --gas-limit {{fusaka_tx_gas_limit}} \
    --sig 'run()'

publish-sources address contract_path constructor_args:
  forge verify-contract {{address}} \
    --verifier etherscan \
    --rpc-url {{env('RPC_URL')}} \
    --constructor-args {{constructor_args}} \
    --watch \
    -vvvv

test-integration path='test/integration/**/*.test.sol':
	forge test {{path}} --fork-url {{env('RPC_URL')}}

test-unit:
  FOUNDRY_PROFILE=test forge test --no-match-path 'test/integration/*' test