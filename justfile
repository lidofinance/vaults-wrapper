set dotenv-load := true
set unstable := true

fusaka_tx_gas_limit := '16777216'

default:
  @just --list

# Private recipe to build common forge script flags (lazy evaluation)
[private]
_script-flags rpc_url deployer private_key:
  #!/usr/bin/env bash
  set -euo pipefail
  VERIFY_FLAGS=""
  if [ -n "${PUBLISH_SOURCES:-}" ]; then
    VERIFY_FLAGS="--verify --verifier etherscan --retries 20 --delay 15"
  fi
  echo "--rpc-url {{rpc_url}} --broadcast --sender {{deployer}} --private-key {{private_key}} --slow $VERIFY_FLAGS --non-interactive"

deploy-factory:
  forge script script/DeployFactory.s.sol:DeployFactory $(just _script-flags {{env('RPC_URL')}} {{env('DEPLOYER')}} {{env('PRIVATE_KEY')}}) --sig 'run()'

deploy-pool FACTORY_ADDRESS POOL_PARAMS_JSON:
  POOL_PARAMS_JSON={{POOL_PARAMS_JSON}} \
  FACTORY_ADDRESS={{FACTORY_ADDRESS}} \
  forge script script/DeployPool.s.sol:DeployPool $(just _script-flags {{env('RPC_URL')}} {{env('DEPLOYER')}} {{env('PRIVATE_KEY')}}) -vvvv --sig 'run()'

deploy-pool-start FACTORY_ADDRESS POOL_PARAMS_JSON:
  DEPLOY_MODE=start \
  POOL_PARAMS_JSON={{POOL_PARAMS_JSON}} \
  FACTORY_ADDRESS={{FACTORY_ADDRESS}} \
  forge script script/DeployPool.s.sol:DeployPool $(just _script-flags {{env('RPC_URL')}} {{env('DEPLOYER')}} {{env('PRIVATE_KEY')}}) --gas-estimate-multiplier 110 --sig 'run()'

deploy-pool-finish FACTORY_ADDRESS INTERMEDIATE_JSON:
  DEPLOY_MODE=finish \
  INTERMEDIATE_JSON={{INTERMEDIATE_JSON}} \
  FACTORY_ADDRESS={{FACTORY_ADDRESS}} \
  forge script script/DeployPool.s.sol:DeployPool $(just _script-flags {{env('RPC_URL')}} {{env('DEPLOYER')}} {{env('PRIVATE_KEY')}}) --gas-estimate-multiplier 110 --sig 'run()'

deploy-all env_file:
  #!/usr/bin/env bash
  set -euxo pipefail
  source {{env_file}}
  just deploy-factory
  export FACTORY=$(jq -r '.deployment.factory' deployments/pool-factory-latest.json)
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
  forge script script/DeployGGVMocks.s.sol:DeployGGVMocks $(just _script-flags) --gas-limit {{fusaka_tx_gas_limit}} --sig 'run()'

publish-sources address contract_path constructor_args:
  forge verify-contract {{address}} {{contract_path}} \
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

verify-all:
  #!/usr/bin/env bash
  set -euo pipefail
  
  DEPLOYMENT_JSON="deployments/pool-factory-latest.json"
  FACTORY_CONFIG="config/hoodi-factory.json"
  
  FACTORY=$(jq -r '.deployment.factory' "$DEPLOYMENT_JSON")
  GGV_STRATEGY_FACTORY=$(jq -r '.factories.ggvStrategyFactory' "$DEPLOYMENT_JSON")
  STV_POOL_FACTORY=$(jq -r '.factories.stvPoolFactory' "$DEPLOYMENT_JSON")
  STV_STETH_POOL_FACTORY=$(jq -r '.factories.stvStETHPoolFactory' "$DEPLOYMENT_JSON")
  WITHDRAWAL_QUEUE_FACTORY=$(jq -r '.factories.withdrawalQueueFactory' "$DEPLOYMENT_JSON")
  TIMELOCK_FACTORY=$(jq -r '.factories.timelockFactory' "$DEPLOYMENT_JSON")
  DISTRIBUTOR_FACTORY=$(jq -r '.factories.distributorFactory' "$DEPLOYMENT_JSON")
  
  LOCATOR=$(jq -r '.lidoLocator' "$FACTORY_CONFIG")
  TELLER=$(jq -r '.strategies.ggv.teller' "$FACTORY_CONFIG")
  BORING_QUEUE=$(jq -r '.strategies.ggv.boringOnChainQueue' "$FACTORY_CONFIG")
  
  echo "Verifying contracts..."
  echo "Factory: $FACTORY"
  echo ""
  
  echo "1. Verifying StvPoolFactory..."
  forge verify-contract "$STV_POOL_FACTORY" src/factories/StvPoolFactory.sol:StvPoolFactory \
    --verifier etherscan --rpc-url {{env('RPC_URL')}} --watch -vvvv || echo "Failed to verify StvPoolFactory"
  
  echo ""
  echo "2. Verifying StvStETHPoolFactory..."
  forge verify-contract "$STV_STETH_POOL_FACTORY" src/factories/StvStETHPoolFactory.sol:StvStETHPoolFactory \
    --verifier etherscan --rpc-url {{env('RPC_URL')}} --watch -vvvv || echo "Failed to verify StvStETHPoolFactory"
  
  echo ""
  echo "3. Verifying WithdrawalQueueFactory..."
  forge verify-contract "$WITHDRAWAL_QUEUE_FACTORY" src/factories/WithdrawalQueueFactory.sol:WithdrawalQueueFactory \
    --verifier etherscan --rpc-url {{env('RPC_URL')}} --watch -vvvv || echo "Failed to verify WithdrawalQueueFactory"
  
  echo ""
  echo "4. Verifying TimelockFactory..."
  forge verify-contract "$TIMELOCK_FACTORY" src/factories/TimelockFactory.sol:TimelockFactory \
    --verifier etherscan --rpc-url {{env('RPC_URL')}} --watch -vvvv || echo "Failed to verify TimelockFactory"
  
  echo ""
  echo "5. Verifying DistributorFactory..."
  forge verify-contract "$DISTRIBUTOR_FACTORY" src/factories/DistributorFactory.sol:DistributorFactory \
    --verifier etherscan --rpc-url {{env('RPC_URL')}} --watch -vvvv || echo "Failed to verify DistributorFactory"
  
  echo ""
  echo "6. Verifying GGVStrategyFactory..."
  GGV_ARGS=$(cast abi-encode "constructor(address,address)" "$TELLER" "$BORING_QUEUE")
  forge verify-contract "$GGV_STRATEGY_FACTORY" src/factories/GGVStrategyFactory.sol:GGVStrategyFactory \
    --verifier etherscan --rpc-url {{env('RPC_URL')}} --constructor-args "$GGV_ARGS" --watch -vvvv || echo "Failed to verify GGVStrategyFactory"
  
  echo ""
  echo "7. Verifying Factory..."

  FACTORY_ARGS=$(cast abi-encode \
    "constructor(address,(address,address,address,address,address,address))" \
    "$LOCATOR" \
    "($STV_POOL_FACTORY,$STV_STETH_POOL_FACTORY,$WITHDRAWAL_QUEUE_FACTORY,$DISTRIBUTOR_FACTORY,$GGV_STRATEGY_FACTORY,$TIMELOCK_FACTORY)")
  forge verify-contract "$FACTORY" src/Factory.sol:Factory \
    --verifier etherscan --rpc-url {{env('RPC_URL')}} --constructor-args "$FACTORY_ARGS" --watch -vvvv || echo "Failed to verify Factory"
  
  echo ""
  echo "Verification complete!"