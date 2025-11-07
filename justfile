set dotenv-load := true
set unstable := true

fusaka_tx_gas_limit := '16777216'
verify_flags := if env('PUBLISH_SOURCES', '') != '' {
  '--verify --verifier etherscan --retries 20 --delay 15'
} else {
  ''
}
common_script_flags := "--rpc-url " + env('RPC_URL') + " --broadcast --sender " + env('DEPLOYER') + " --private-key " + env('PRIVATE_KEY') + " --slow " + verify_flags + " --non-interactive" + " --gas-estimate-multiplier " + "100"

default:
  @just --list

deploy-factory:
  forge script script/DeployFactory.s.sol:DeployFactory \
    {{common_script_flags}} \
    --sig 'run()'

deploy-pool FACTORY_ADDRESS POOL_PARAMS_JSON:
  POOL_PARAMS_JSON={{POOL_PARAMS_JSON}} \
  FACTORY_ADDRESS={{FACTORY_ADDRESS}} \
  forge script script/DeployPool.s.sol:DeployPool \
    {{common_script_flags}} \
    -vvvv \
    --sig 'run()'

deploy-pool-start FACTORY_ADDRESS POOL_PARAMS_JSON:
  DEPLOY_MODE=start \
  POOL_PARAMS_JSON={{POOL_PARAMS_JSON}} \
  FACTORY_ADDRESS={{FACTORY_ADDRESS}} \
  forge script script/DeployPool.s.sol:DeployPool \
    {{common_script_flags}} \
    --sig 'run()'

deploy-pool-finish FACTORY_ADDRESS INTERMEDIATE_JSON:
  DEPLOY_MODE=finish \
  INTERMEDIATE_JSON={{INTERMEDIATE_JSON}} \
  FACTORY_ADDRESS={{FACTORY_ADDRESS}} \
  forge script script/DeployPool.s.sol:DeployPool \
    {{common_script_flags}} \
    -vvvv \
    --sig 'run()'

deploy-all env_file:
  #!/usr/bin/env bash
  set -euxo pipefail
  source {{env_file}}
  # just deploy-factory
  export FACTORY=$(jq '.deployment.factory' deployments/pool-factory-latest.json)
  export NOW=$(date -Iseconds | sed 's/+.*//')

  # export POOL_CONFIG_NAME="hoodi-stv.json"
  # export INTERMEDIATE_JSON="deployments/intermediate-${NOW}-${POOL_CONFIG_NAME}"
  # just deploy-pool-start $FACTORY "config/${POOL_CONFIG_NAME}"
  # just deploy-pool-finish $FACTORY $INTERMEDIATE_JSON

  export POOL_CONFIG_NAME="hoodi-stv-steth.json"
  export INTERMEDIATE_JSON="deployments/intermediate-${NOW}-${POOL_CONFIG_NAME}"
  just deploy-pool-start $FACTORY "config/${POOL_CONFIG_NAME}"
  just deploy-pool-finish $FACTORY $INTERMEDIATE_JSON

  # export POOL_CONFIG_NAME="hoodi-stv-ggv.json"
  # export INTERMEDIATE_JSON="deployments/intermediate-${NOW}-${POOL_CONFIG_NAME}"
  # just deploy-pool-start $FACTORY "config/${POOL_CONFIG_NAME}"
  # just deploy-pool-finish $FACTORY $INTERMEDIATE_JSON


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