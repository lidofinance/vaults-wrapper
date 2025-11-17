set dotenv-load := true
set unstable := true

fusaka_tx_gas_limit := '16777216'
verify_flags := if env('PUBLISH_SOURCES', '') != '' {
  '--verify --verifier etherscan --retries 20 --delay 15'
} else {
  ''
}
common_script_flags := "--rpc-url " + env('RPC_URL') + " --broadcast --sender " + env('DEPLOYER') + " --private-key " + env('PRIVATE_KEY') + " --slow " + verify_flags + " --non-interactive"

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
    --gas-estimate-multiplier 110 \
    --sig 'run()'

deploy-pool-finish FACTORY_ADDRESS INTERMEDIATE_JSON:
  DEPLOY_MODE=finish \
  INTERMEDIATE_JSON={{INTERMEDIATE_JSON}} \
  FACTORY_ADDRESS={{FACTORY_ADDRESS}} \
  forge script script/DeployPool.s.sol:DeployPool \
    {{common_script_flags}} \
    --gas-estimate-multiplier 110 \
    --sig 'run()'

deploy-all env_file:
  #!/usr/bin/env bash
  set -euxo pipefail
  source {{env_file}}
  just deploy-factory
  export FACTORY=$(jq '.deployment.factory' deployments/pool-factory-latest.json)
  export NOW=$(date -Iseconds | sed 's/+.*//')

  export POOL_CONFIG_NAME="hoodi-stv.json"
  export INTERMEDIATE_JSON="deployments/intermediate-${NOW}-${POOL_CONFIG_NAME}"
  just deploy-pool-start $FACTORY "config/${POOL_CONFIG_NAME}"
  just deploy-pool-finish $FACTORY $INTERMEDIATE_JSON

  export POOL_CONFIG_NAME="hoodi-stv-steth.json"
  export INTERMEDIATE_JSON="deployments/intermediate-${NOW}-${POOL_CONFIG_NAME}"
  just deploy-pool-start $FACTORY "config/${POOL_CONFIG_NAME}"
  just deploy-pool-finish $FACTORY $INTERMEDIATE_JSON

  export POOL_CONFIG_NAME="hoodi-stv-ggv.json"
  export INTERMEDIATE_JSON="deployments/intermediate-${NOW}-${POOL_CONFIG_NAME}"
  just deploy-pool-start $FACTORY "config/${POOL_CONFIG_NAME}"
  just deploy-pool-finish $FACTORY $INTERMEDIATE_JSON


deploy-ggv-mocks:
  STETH={{env('STETH')}} \
  WSTETH={{env('WSTETH')}} \
  GGV_OWNER={{env('GGV_OWNER')}} \
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

test-integration path='**/*.test.sol':
	forge test 'test/integration/{{path}}' --fork-url {{env('RPC_URL')}}

test-unit:
  FOUNDRY_PROFILE=test forge test --no-match-path 'test/integration/*' test

# Core deployment recipes
core-init branch='feat/vaults' subdir='lido-core':
  #!/usr/bin/env bash
  set -euxo pipefail
  rm -rf ./{{subdir}}
  git clone https://github.com/lidofinance/core.git -b {{branch}} --depth 1 {{subdir}}
  cd {{subdir}}
  corepack enable
  yarn install --frozen-lockfile

core-deploy subdir='lido-core' rpc_port='9123':
  #!/usr/bin/env bash
  set -euxo pipefail
  cd {{subdir}}
  NETWORK=local \
  GENESIS_TIME=1639659600 \
  GAS_PRIORITY_FEE=1 \
  GAS_MAX_FEE=100 \
  NETWORK_STATE_FILE="deployed-local.json" \
  NETWORK_STATE_DEFAULTS_FILE="scripts/defaults/testnet-defaults.json" \
  RPC_URL=http://localhost:{{rpc_port}} \
  SKIP_CONTRACT_SIZE=true \
  SKIP_GAS_REPORT=true \
  SKIP_INTERFACES_CHECK=true \
  LOG_LEVEL=warn \
  DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
  bash scripts/dao-deploy.sh
