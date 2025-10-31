.ONESHELL:

CORE_RPC_PORT ?= 9123
CORE_BRANCH ?= feat/vaults
CORE_SUBDIR ?= lido-core
NETWORK ?= local
VERBOSITY ?= vv
DEBUG_TEST ?= test_debug


test-integration-a:
	[ -f .env ] && . .env; \
	FOUNDRY_PROFILE=test \
	CORE_LOCATOR_ADDRESS="$$CORE_LOCATOR_ADDRESS" \
	forge test \
		test/integration/stv-pool.test.sol \
		-$(VERBOSITY) \
		--fork-url "$$RPC_URL"

test-integration-b:
	[ -f .env ] && . .env; \
	FOUNDRY_PROFILE=test \
	CORE_LOCATOR_ADDRESS="$$CORE_LOCATOR_ADDRESS" \
	forge test \
		test/integration/stv-steth-pool.test.sol \
		-$(VERBOSITY) \
		--fork-url "$$RPC_URL"


test-integration-ggv:
	[ -f .env ] && . .env; \
	FOUNDRY_PROFILE=test \
	CORE_LOCATOR_ADDRESS="$$CORE_LOCATOR_ADDRESS" \
	forge test \
		test/integration/ggv.test.sol \
		-$(VERBOSITY) \
		--fork-url "$$RPC_URL"

test-integration:
	[ -f .env ] && . .env; \
	FOUNDRY_PROFILE=test CORE_LOCATOR_ADDRESS="$$CORE_LOCATOR_ADDRESS" forge test test/integration/**/*.test.sol -$(VERBOSITY) --fork-url "$$RPC_URL"

test-integration-debug:
	[ -f .env ] && . .env; \
	FOUNDRY_PROFILE=test CORE_LOCATOR_ADDRESS="$$CORE_LOCATOR_ADDRESS" forge test --match-test $(DEBUG_TEST) -$(VERBOSITY) --fork-url "$$RPC_URL"

test-unit:
	FOUNDRY_PROFILE=test forge test -$(VERBOSITY) --no-match-path 'test/integration/*' test

test-all:
	make test-unit
	make test-integration

deploy-factory:
	[ -f .env ] && . .env; \
	VERIFY_FLAGS=""; \
	if [ -n "$$PUBLISH_SOURCES" ]; then \
		export ETHERSCAN_API_KEY="$${ETHERSCAN_API_KEY:-$${ETHERSCAN_TOKEN}}"; \
		VERIFY_FLAGS="--verify --verifier etherscan"; \
	fi; \
	GAS_FLAGS=""; \
	if [ -n "$$GAS_PRIORITY_FEE" ]; then \
		GAS_FLAGS="$$GAS_FLAGS --priority-gas-price $$GAS_PRIORITY_FEE"; \
	fi; \
	if [ -n "$$GAS_MAX_FEE" ]; then \
		GAS_FLAGS="$$GAS_FLAGS --with-gas-price $$GAS_MAX_FEE"; \
	fi; \
	OUTPUT_JSON=$(OUTPUT_JSON) \
	forge script script/DeployFactory.s.sol:DeployFactory \
		--rpc-url $${RPC_URL:-http://localhost:9123} \
		--broadcast \
		--private-key $${PRIVATE_KEY:-$(PRIVATE_KEY)} \
		--sender $${DEPLOYER:-$(DEPLOYER)} \
		$$VERIFY_FLAGS \
		$$GAS_FLAGS \
		--enable-tx-gas-limit \
		--slow \
		--sig 'run()' \
		--non-interactive

# Usage: make deploy-pool-from-factory PARAMS_JSON=./myparams.json
deploy-pool-from-factory:
	[ -f .env ] && . .env; \
	if [ ! -f "$$PARAMS_JSON" ]; then \
		echo "Error: PARAMS_JSON must be set and point to an existing file (e.g. make deploy-pool-from-factory PARAMS_JSON=./myparams.json)"; \
		exit 1; \
	fi; \
	VERIFY_FLAGS=""; \
	if [ -n "$$PUBLISH_SOURCES" ]; then \
		export ETHERSCAN_API_KEY="$${ETHERSCAN_API_KEY:-$${ETHERSCAN_TOKEN}}"; \
		VERIFY_FLAGS="--verify --verifier etherscan"; \
	fi; \
	GAS_FLAGS=""; \
	if [ -n "$$GAS_PRIORITY_FEE" ]; then \
		GAS_FLAGS="$$GAS_FLAGS --priority-gas-price $$GAS_PRIORITY_FEE"; \
	fi; \
	if [ -n "$$GAS_MAX_FEE" ]; then \
		GAS_FLAGS="$$GAS_FLAGS --with-gas-price $$GAS_MAX_FEE"; \
	fi; \
	export POOL_PARAMS_JSON="$$PARAMS_JSON"; \
	forge script script/DeployPool.s.sol:DeployWrapper \
		--rpc-url $${RPC_URL} \
		--broadcast \
		--sender $${DEPLOYER:-$(DEPLOYER)} \
		--private-key $${PRIVATE_KEY:-$(PRIVATE_KEY)} \
		$$VERIFY_FLAGS \
		$$GAS_FLAGS \
		--enable-tx-gas-limit \
		--slow \
		--sig 'run()' \
		--non-interactive


publish-pool-sources:
	[ -f .env ] && . .env; \
	if [ -z "$$ETHERSCAN_API_KEY" ] && [ -z "$$ETHERSCAN_TOKEN" ]; then \
		echo "ETHERSCAN_API_KEY or ETHERSCAN_TOKEN must be set"; \
		exit 1; \
	fi; \
	export ETHERSCAN_API_KEY="$${ETHERSCAN_API_KEY:-$${ETHERSCAN_TOKEN}}"; \
	FILE=$${WRAPPER_DEPLOYED_JSON:-$${WRAPPER_DEPLOYED_JSON:-./deployments/pool-deployed-$${NETWORK:-$(NETWORK)}.json}}; \
	if [ ! -f "$$FILE" ]; then \
		echo "Wrapper artifact not found: $$FILE"; \
		exit 1; \
	fi; \
		ADDR_WRAPPER=$$(jq -r '.pool // .poolProxy // .deployment.pool // empty' $$FILE 2>/dev/null); \
		ADDR_WQ=$$(jq -r '.withdrawalQueue // .deployment.withdrawalQueue // empty' $$FILE 2>/dev/null); \
		ADDR_WRAPPER_IMPL=$$(jq -r '.poolImpl // .deployment.poolImpl // empty' $$FILE 2>/dev/null); \
		ADDR_WQ_IMPL=$$(jq -r '.withdrawalQueueImpl // .deployment.withdrawalQueueImpl // empty' $$FILE 2>/dev/null); \
		ADDR_STRATEGY=$$(jq -r '.strategy // .deployment.strategy // empty' $$FILE 2>/dev/null); \
		WRAPPER_PROXY_ARGS=$$(jq -r '.poolProxyCtorArgs // empty' $$FILE 2>/dev/null | sed 's/^null$$//'); \
		WQ_PROXY_ARGS=$$(jq -r '.withdrawalQueueProxyCtorArgs // empty' $$FILE 2>/dev/null | sed 's/^null$$//'); \
		WRAPPER_IMPL_ARGS=$$(jq -r '.poolImplCtorArgs // empty' $$FILE 2>/dev/null | sed 's/^null$$//'); \
		WQ_IMPL_ARGS=$$(jq -r '.withdrawalQueueImplCtorArgs // empty' $$FILE 2>/dev/null | sed 's/^null$$//'); \
		STRATEGY_ARGS=$$(jq -r '.strategyCtorArgs // empty' $$FILE 2>/dev/null | sed 's/^null$$//'); \
	WRAPPER_TYPE=$$(jq -r '.poolType // .pool.poolType // empty' $$FILE 2>/dev/null); \
	WRAPPER_CONTRACT=$${WRAPPER_IMPL_CONTRACT}; \
	echo "Using artifact: $$FILE"; \
	echo "Parsed addresses:"; \
	echo "  pool proxy: $$ADDR_WRAPPER"; \
	echo "  pool impl:  $$ADDR_WRAPPER_IMPL"; \
	echo "  wq proxy:      $$ADDR_WQ"; \
	echo "  wq impl:       $$ADDR_WQ_IMPL"; \
	echo "  strategy:      $$ADDR_STRATEGY"; \
	if [ -z "$$ADDR_WRAPPER" ] || [ "$$ADDR_WRAPPER" = "null" ] || \
	   [ -z "$$ADDR_WQ" ] || [ "$$ADDR_WQ" = "null" ] || \
	   [ -z "$$ADDR_WRAPPER_IMPL" ] || [ "$$ADDR_WRAPPER_IMPL" = "null" ] || \
	   [ -z "$$ADDR_WQ_IMPL" ] || [ "$$ADDR_WQ_IMPL" = "null" ]; then \
		echo "One or more required contract addresses are missing or null."; \
		exit 1; \
	fi; \
	if [ -z "$$WRAPPER_CONTRACT" ]; then \
		case "$$WRAPPER_TYPE" in \
			"0") WRAPPER_CONTRACT="src/StvPool.sol:StvPool";; \
			"1") WRAPPER_CONTRACT="src/StvStETHPool.sol:StvStETHPool";; \
			"2"|"3") WRAPPER_CONTRACT="src/StvStrategyPool.sol:StvStrategyPool";; \
			*) WRAPPER_CONTRACT="src/StvPool.sol:StvPool";; \
		esac; \
	fi; \
		forge verify-contract $$ADDR_WRAPPER src/proxy/OssifiableProxy.sol:OssifiableProxy \
			--verifier $${VERIFIER:-etherscan} $$( [ -n "$$VERIFIER_URL" ] && echo --verifier-url $${VERIFIER_URL} ) --rpc-url $${RPC_URL} \
			$$( [ -n "$$WRAPPER_PROXY_ARGS" ] && echo --constructor-args "$$WRAPPER_PROXY_ARGS" ) \
		--watch \
		-vvvv || true; \
		forge verify-contract $$ADDR_WQ src/proxy/OssifiableProxy.sol:OssifiableProxy \
			--verifier $${VERIFIER:-etherscan} $$( [ -n "$$VERIFIER_URL" ] && echo --verifier-url $${VERIFIER_URL} ) --rpc-url $${RPC_URL} \
			$$( [ -n "$$WQ_PROXY_ARGS" ] && echo --constructor-args "$$WQ_PROXY_ARGS" ) \
		--watch \
		-vvvv || true; \
		forge verify-contract $$ADDR_WRAPPER_IMPL $$WRAPPER_CONTRACT \
			--verifier $${VERIFIER:-etherscan} $$( [ -n "$$VERIFIER_URL" ] && echo --verifier-url $${VERIFIER_URL} ) --rpc-url $${RPC_URL} \
			$$( [ -n "$$WRAPPER_IMPL_ARGS" ] && echo --constructor-args "$$WRAPPER_IMPL_ARGS" ) \
		--watch \
		-vvvv || true; \
		forge verify-contract $$ADDR_WQ_IMPL src/WithdrawalQueue.sol:WithdrawalQueue \
			--verifier $${VERIFIER:-etherscan} $$( [ -n "$$VERIFIER_URL" ] && echo --verifier-url $${VERIFIER_URL} ) --rpc-url $${RPC_URL} \
			$$( [ -n "$$WQ_IMPL_ARGS" ] && echo --constructor-args "$$WQ_IMPL_ARGS" ) \
		--watch \
		-vvvv || true; \
	if [ -n "$$ADDR_STRATEGY" ] && [ "$$ADDR_STRATEGY" != "0x0000000000000000000000000000000000000000" ] && [ "$$ADDR_STRATEGY" != "null" ]; then \
			forge verify-contract $$ADDR_STRATEGY src/strategy/GGVStrategy.sol:GGVStrategy \
				--verifier $${VERIFIER:-etherscan} $$( [ -n "$$VERIFIER_URL" ] && echo --verifier-url $${VERIFIER_URL} ) --rpc-url $${RPC_URL} \
				$$( [ -n "$$STRATEGY_ARGS" ] && echo --constructor-args "$$STRATEGY_ARGS" ) \
			--watch \
			-vvvv || true; \
	fi

deploy-ggv-mocks:
	[ -f .env ] && . .env; \
	OUTPUT_JSON=$${GGV_MOCKS_DEPLOYED_JSON:-deployments/ggv-mocks-$${NETWORK:-$(NETWORK)}.json}; \
	forge script script/DeployGGVMocks.s.sol:DeployGGVMocks \
		--rpc-url $${RPC_URL} \
		--broadcast \
		--sender $${DEPLOYER:-$(DEPLOYER)} \
		--private-key $${PRIVATE_KEY:-$(PRIVATE_KEY)} \
		-vvvv \
		--sig 'run()' \
		--non-interactive \
		--json; \
	echo "Mocks written to $$OUTPUT_JSON (see logs for exact path if overridden)"

# Requires entr util
test-watch:
	find . -type f -name '*.sol' | entr -r bash -c 'make test-integration-debug'

core-init:
	rm -rf ./$(CORE_SUBDIR)
	git clone https://github.com/lidofinance/core.git -b $(CORE_BRANCH) --depth 1 $(CORE_SUBDIR)

	cd $(CORE_SUBDIR) && \
	corepack enable && \
	yarn install --frozen-lockfile

core-deploy:
	cd $(CORE_SUBDIR) && \
	NETWORK=local \
	GENESIS_TIME=1639659600 \
	GAS_PRIORITY_FEE=1 \
	GAS_MAX_FEE=100 \
	NETWORK_STATE_FILE="deployed-local.json" \
	NETWORK_STATE_DEFAULTS_FILE="scripts/defaults/testnet-defaults.json" \
	RPC_URL=http://localhost:$(CORE_RPC_PORT) \
	SKIP_CONTRACT_SIZE=true SKIP_GAS_REPORT=true SKIP_INTERFACES_CHECK=true LOG_LEVEL=warn \
	DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
	bash scripts/dao-deploy.sh

harness-core:
	forge script script/HarnessCore.s.sol:HarnessCore --ffi

start-fork:
	anvil --chain-id 1 --auto-impersonate --port $(CORE_RPC_PORT)

start-fork-no-size-limit:
	anvil --chain-id 1 --auto-impersonate --port $(CORE_RPC_PORT) --disable-code-size-limit

start-fork-from-rpc:
	[ -f .env ] && . .env; \
	if [ -z "$$RPC_URL_TO_FORK" ]; then \
		echo "RPC_URL_TO_FORK must be set"; \
		exit 1; \
	fi; \
	anvil --fork-url "$$RPC_URL_TO_FORK" --auto-impersonate --port $(CORE_RPC_PORT)

mock-deploy:
	PRIVATE_KEY=$(PRIVATE_KEY) \
	VAULT_FACTORY=$(VAULT_FACTORY) \
	STETH=$(STETH) \
	forge script script/DeployWrapper.s.sol --rpc-url $(RPC_URL) --broadcast

mock-strategy:
	PRIVATE_KEY=$(PRIVATE_KEY) \
	VAULT_FACTORY=$(VAULT_FACTORY) \
	STETH=$(STETH) \
	forge script script/DeployStrategy.s.sol --rpc-url $(RPC_URL) --broadcast

deploy-all:
	[ -f .env ] && . .env; \
	set -e; \
	# 1) Deploy Factory using existing make target
	CORE_LOCATOR_ADDRESS="$$CORE_LOCATOR_ADDRESS" \
	FACTORY_PARAMS_JSON="$$FACTORY_PARAMS_JSON" \
	RPC_URL="$$RPC_URL" \
	PRIVATE_KEY="$$PRIVATE_KEY" \
	DEPLOYER="$$DEPLOYER" \
	PUBLISH_SOURCES="$$PUBLISH_SOURCES" \
	GAS_PRIORITY_FEE="$$GAS_PRIORITY_FEE" \
	GAS_MAX_FEE="$$GAS_MAX_FEE" \
	$(MAKE) -s deploy-factory; \
	# 2) Deploy all wrappers from configs using existing make target
	WRAPPER_CONFIGS=$${WRAPPER_CONFIGS:-"script/stv-pool-deploy-config-hoodi.json script/stv-steth-pool-deploy-config-hoodi.json script/stv-ggv-pool-deploy-config-hoodi.json "}; \
	CHAIN_ID=$$(cast chain-id --rpc-url "$$RPC_URL"); \
	for CFG in $$WRAPPER_CONFIGS; do \
		if [ -f "$$CFG" ]; then \
			BASENAME=$$(basename "$$CFG" .json); \
			OUT="deployments/pool-instance-$$BASENAME-$$CHAIN_ID-$$(date +%s).json"; \
			WRAPPER_DEPLOYED_JSON="$$OUT" \
			BUMP_CORE_FACTORY_NONCE="$$${BUMP_CORE_FACTORY_NONCE:-0}" \
			RPC_URL="$$RPC_URL" \
			DEPLOYER="$$DEPLOYER" \
			PRIVATE_KEY="$$PRIVATE_KEY" \
			GAS_PRIORITY_FEE="$$GAS_PRIORITY_FEE" \
			GAS_MAX_FEE="$$GAS_MAX_FEE" \
			$(MAKE) -s deploy-pool-from-factory PARAMS_JSON="$$CFG"; \
			echo "Deployed wrapper: $$CFG -> $$OUT"; \
		else \
			echo "Config not found, skipping: $$CFG"; \
		fi; \
	done

# WRAPPER_CONFIGS=$${WRAPPER_CONFIGS:-"script/stv-pool-deploy-config-hoodi.json script/stv-steth-pool-deploy-config-hoodi.json script/stv-ggv-pool-deploy-config-hoodi.json"}; \