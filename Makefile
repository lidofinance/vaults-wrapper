.ONESHELL:

CORE_RPC_PORT ?= 9123
CORE_BRANCH ?= feat/testnet-2
CORE_SUBDIR ?= lido-core
NETWORK ?= local
VERBOSITY ?= vv
DEBUG_TEST ?= test_debug


test-integration-b:
	. .env 2>/dev/null || true; \
	FOUNDRY_PROFILE=test CORE_DEPLOYED_JSON="$$CORE_DEPLOYED_JSON" forge test test/integration/wrapper-b.test.sol -$(VERBOSITY) --fork-url "$$RPC_URL"

test-integration:
	. .env 2>/dev/null || true; \
	FOUNDRY_PROFILE=test CORE_DEPLOYED_JSON="$$CORE_DEPLOYED_JSON" forge test test/integration/**/*.test.sol -$(VERBOSITY) --fork-url "$$RPC_URL"

test-integration-debug:
	. .env 2>/dev/null || true; \
	FOUNDRY_PROFILE=test CORE_DEPLOYED_JSON="$$CORE_DEPLOYED_JSON" forge test --match-test $(DEBUG_TEST) -$(VERBOSITY) --fork-url $${RPC_URL}
	# FOUNDRY_PROFILE=test forge test test/integration/**/*.test.sol -vv --fork-url $(RPC_URL)

test-unit:
	FOUNDRY_PROFILE=test forge test -$(VERBOSITY) --no-match-path 'test/integration/*' test

test-all:
	make test-unit
	make test-integration

deploy-factory:
	. .env 2>/dev/null || true; \
	VERIFY_FLAGS=""; \
	if [ -n "$$PUBLISH_SOURCES" ]; then \
		export ETHERSCAN_API_KEY="$${ETHERSCAN_API_KEY:-$${ETHERSCAN_TOKEN}}"; \
		VERIFY_FLAGS="--verify --verifier etherscan"; \
	fi; \
	OUTPUT_JSON=$(OUTPUT_JSON) \
	forge script script/DeployWrapperFactory.s.sol:DeployWrapperFactory \
		--rpc-url $${RPC_URL:-http://localhost:9123} \
		--broadcast \
		--private-key $${PRIVATE_KEY:-$(PRIVATE_KEY)} \
		--sender $${DEPLOYER:-$(DEPLOYER)} \
		$$VERIFY_FLAGS \
		--slow \
		-vvvv \
		--sig 'run()' \
		--non-interactive

deploy-wrapper-from-factory:
	. .env 2>/dev/null || true; \
	FACTORY_JSON=$${FACTORY_JSON:-$(OUTPUT_JSON)} \
	WRAPPER_PARAMS_JSON=$${WRAPPER_PARAMS_JSON:-$(WRAPPER_PARAMS_JSON)} \
	forge script script/DeployWrapper.s.sol:DeployWrapper \
		BUMP_CORE_FACTORY_NONCE=$${BUMP_CORE_FACTORY_NONCE:-0} \
		--rpc-url $${RPC_URL} \
		--broadcast \
		--sender $${DEPLOYER:-$(DEPLOYER)} \
		--private-key $${PRIVATE_KEY:-$(PRIVATE_KEY)} \
		--slow \
		-vvvv \
		--sig 'run()' \
		--non-interactive


publish-wrapper-sources:
	. .env 2>/dev/null || true; \
	if [ -z "$$ETHERSCAN_API_KEY" ] && [ -z "$$ETHERSCAN_TOKEN" ]; then \
		echo "ETHERSCAN_API_KEY or ETHERSCAN_TOKEN must be set"; \
		exit 1; \
	fi; \
	export ETHERSCAN_API_KEY="$${ETHERSCAN_API_KEY:-$${ETHERSCAN_TOKEN}}"; \
	FILE=$${WRAPPER_DEPLOYED_JSON:-$${WRAPPER_DEPLOYED_JSON:-./deployments/wrapper-deployed-$${NETWORK:-$(NETWORK)}.json}}; \
	if [ ! -f "$$FILE" ]; then \
		echo "Wrapper artifact not found: $$FILE"; \
		exit 1; \
	fi; \
		ADDR_WRAPPER=$$(jq -r '.wrapper // .wrapperProxy // .deployment.wrapper // empty' $$FILE 2>/dev/null); \
		ADDR_WQ=$$(jq -r '.withdrawalQueue // .deployment.withdrawalQueue // empty' $$FILE 2>/dev/null); \
		ADDR_WRAPPER_IMPL=$$(jq -r '.wrapperImpl // .deployment.wrapperImpl // empty' $$FILE 2>/dev/null); \
		ADDR_WQ_IMPL=$$(jq -r '.withdrawalQueueImpl // .deployment.withdrawalQueueImpl // empty' $$FILE 2>/dev/null); \
		ADDR_STRATEGY=$$(jq -r '.strategy // .deployment.strategy // empty' $$FILE 2>/dev/null); \
		WRAPPER_PROXY_ARGS=$$(jq -r '.wrapperProxyCtorArgs // empty' $$FILE 2>/dev/null | sed 's/^null$$//'); \
		WQ_PROXY_ARGS=$$(jq -r '.withdrawalQueueProxyCtorArgs // empty' $$FILE 2>/dev/null | sed 's/^null$$//'); \
		WRAPPER_IMPL_ARGS=$$(jq -r '.wrapperImplCtorArgs // empty' $$FILE 2>/dev/null | sed 's/^null$$//'); \
		WQ_IMPL_ARGS=$$(jq -r '.withdrawalQueueImplCtorArgs // empty' $$FILE 2>/dev/null | sed 's/^null$$//'); \
		STRATEGY_ARGS=$$(jq -r '.strategyCtorArgs // empty' $$FILE 2>/dev/null | sed 's/^null$$//'); \
	WRAPPER_TYPE=$$(jq -r '.wrapperType // .wrapper.wrapperType // empty' $$FILE 2>/dev/null); \
	WRAPPER_CONTRACT=$${WRAPPER_IMPL_CONTRACT}; \
	echo "Using artifact: $$FILE"; \
	echo "Parsed addresses:"; \
	echo "  wrapper proxy: $$ADDR_WRAPPER"; \
	echo "  wrapper impl:  $$ADDR_WRAPPER_IMPL"; \
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
			"0") WRAPPER_CONTRACT="src/WrapperA.sol:WrapperA";; \
			"1") WRAPPER_CONTRACT="src/WrapperB.sol:WrapperB";; \
			"2"|"3") WRAPPER_CONTRACT="src/WrapperC.sol:WrapperC";; \
			*) WRAPPER_CONTRACT="src/WrapperA.sol:WrapperA";; \
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


do-entire-flow-with-core-deploy:
	export NETWORK=$(NETWORK) && \
	export RPC_URL=$(RPC_URL) && \
	export PRIVATE_KEY=$(PRIVATE_KEY) && \
	export DEPLOYER=$(DEPLOYER) && \
	export CORE_DEPLOYED_JSON=$(CORE_DEPLOYED_JSON) && \
	export OUTPUT_JSON=$(OUTPUT_JSON) && \
	export WRAPPER_PARAMS_JSON=$(WRAPPER_PARAMS_JSON) && \
	make core-deploy && \
	rm -f $(CORE_SUBDIR)/deployed-$(NETWORK).json && \
	mv $(CORE_SUBDIR)/deployed-local.json $(CORE_SUBDIR)/deployed-$(NETWORK).json && \
	make harness-core && \
	make deploy-factory && \
	make deploy-wrapper-from-factory && \
	if [ -n "$$PUBLISH_SOURCES" ]; then \
		make publish-wrapper-sources; \
	fi

# Requires entr util
test-watch:
	find . -type f -name '*.sol' | entr -r bash -c 'make test-integration-debug'

core-init:
	rm -rf ./$(CORE_SUBDIR)
	git clone https://github.com/lidofinance/core.git -b $(CORE_BRANCH) --depth 1 $(CORE_SUBDIR)

	cd $(CORE_SUBDIR) && \
	git apply ../test/core-mocking.patch && \
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
	. .env 2>/dev/null || true; \
	if [ -z "$$RPC_URL_TO_FORK" ]; then \
		echo "RPC_URL_TO_FORK must be set"; \
		exit 1; \
	fi; \
	anvil --fork-url "$$RPC_URL_TO_FORK" --auto-impersonate --port $(CORE_RPC_PORT)

core-save-patch:
	cd $(CORE_SUBDIR) && \
	git diff > ../test/core-mocking.patch

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
