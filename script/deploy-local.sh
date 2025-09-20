#!/bin/bash

########################################################
# Factory configuration
########################################################
export MAX_FINALIZATION_TIME=2592000 # 30 days
########################################################


export DEPLOYED_JSON=./lido-core/deployed-local.json
export OUTPUT_JSON=./deployments/wrapper-local.json

########################################################
# Deploy Factory at first
########################################################

PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
SENDER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
forge script script/DeployWrapperFactory.s.sol:DeployWrapperFactory \
  --rpc-url http://localhost:9123 \
  --broadcast \
  --private-key $PRIVATE_KEY \
  --sender $SENDER \
  --sig 'run()' \
  --non-interactive


########################################################
# Deploy Wrapper from the Factory
########################################################

export FACTORY_JSON=$OUTPUT_JSON
export WRAPPER_PARAMS_JSON=script/deploy-local-config.json
export OUTPUT_INSTANCE_JSON=deployments/wrapper-instance.json

forge script script/DeployWrapper.s.sol:DeployWrapper \
  --rpc-url http://localhost:9123 \
  --broadcast \
  --sender $SENDER \
  --private-key $PRIVATE_KEY \
  --sig 'run()' \
  --non-interactive
