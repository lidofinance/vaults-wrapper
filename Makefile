CORE_RPC_PORT ?= 9123
CORE_BRANCH ?= chore/wrapper-dev
CORE_SUBDIR ?= lido-core

test-integration:
	forge test test/integration/**/*.test.sol -vvv --fork-url http://localhost:$(CORE_RPC_PORT)

# Requires entr util
test-watch:
	find . -type f -name '*.sol' | entr -r bash -c 'make test-integration'

core-init:
	rm -rf ./$(CORE_SUBDIR)
	git clone https://github.com/lidofinance/core.git -b $(CORE_BRANCH) --depth 1 $(CORE_SUBDIR)

	cd $(CORE_SUBDIR) && \
	yarn && \
	SKIP_CONTRACTS_SIZE=true SKIP_GAS_REPORT=true yarn compile

core-deploy:
	cd $(CORE_SUBDIR) && \
	NETWORK="local" \
	GENESIS_TIME=1639659600 \
	DEPLOYER="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" \
	GAS_PRIORITY_FEE=1 \
	GAS_MAX_FEE=100 \
	NETWORK_STATE_FILE="deployed-local.json" \
	NETWORK_STATE_DEFAULTS_FILE="scripts/defaults/testnet-defaults.json" \
	RPC_URL=http://localhost:$(CORE_RPC_PORT) \
	bash scripts/dao-deploy.sh

start-fork:
	anvil --chain-id 1 --auto-impersonate --port $(CORE_RPC_PORT)
