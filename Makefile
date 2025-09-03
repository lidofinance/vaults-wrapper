CORE_RPC_PORT ?= 9123
CORE_BRANCH ?= feat/testnet-2
CORE_SUBDIR ?= lido-core
VERBOSITY ?= vv
DEBUG_TEST ?= test_debug
PRIVATE_KEY ?= 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

VAULT_FACTORY ?= 0x86A2EE8FAf9A840F7a2c64CA3d51209F9A02081D
STETH ?= 0xf2A08B9C303496f7FF99Ce2d4A6b6efb65E0e752

test-integration:
	FOUNDRY_PROFILE=test forge test test/integration/**/*.test.sol -$(VERBOSITY) --fork-url http://localhost:$(CORE_RPC_PORT)

test-integration-debug:
	FOUNDRY_PROFILE=test forge test --match-test $(DEBUG_TEST) -$(VERBOSITY) --fork-url http://localhost:$(CORE_RPC_PORT)
	# FOUNDRY_PROFILE=test forge test test/integration/**/*.test.sol -vv --fork-url http://localhost:$(CORE_RPC_PORT)

test-all:
	make test-unit
	make test-integration

test-unit:
	FOUNDRY_PROFILE=test forge test -$(VERBOSITY) --no-match-path 'test/integration/*' test

# Requires entr util
test-watch:
	find . -type f -name '*.sol' | entr -r bash -c 'make test-integration'

core-init:
	rm -rf ./$(CORE_SUBDIR)
	git clone https://github.com/lidofinance/core.git -b $(CORE_BRANCH) --depth 1 $(CORE_SUBDIR)

	cd $(CORE_SUBDIR) && \
	git apply ../test/core-mocking.patch && \
	corepack enable && \
	yarn install --frozen-lockfile

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
	SKIP_CONTRACT_SIZE=true SKIP_GAS_REPORT=true SKIP_INTERFACES_CHECK=true LOG_LEVEL=warn \
	bash scripts/dao-deploy.sh

start-fork:
	anvil --chain-id 1 --auto-impersonate --port $(CORE_RPC_PORT)

core-save-patch:
	cd $(CORE_SUBDIR) && \
	git diff > ../test/core-mocking.patch

mock-deploy:
	PRIVATE_KEY=$(PRIVATE_KEY) \
	VAULT_FACTORY=$(VAULT_FACTORY) \
	STETH=$(STETH) \
	forge script script/DeployWrapper.s.sol --rpc-url localhost:9123 --broadcast

mock-strategy:
	PRIVATE_KEY=$(PRIVATE_KEY) \
	VAULT_FACTORY=$(VAULT_FACTORY) \
	STETH=$(STETH) \
	forge script script/DeployStrategy.s.sol --rpc-url localhost:9123 --broadcast