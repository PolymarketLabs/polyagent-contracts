.DEFAULT_GOAL := help
.PHONY: help test build fmt-check fmt anvil deploy-local deploy-sepolia deploy-mainnet upgrade-local upgrade-sepolia upgrade-mainnet

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"} \
		/^[a-zA-Z_-]+:.*##/ { \
			printf "\033[36m%-20s\033[0m %s\n", $$1, $$2 \
		}' $(MAKEFILE_LIST)

test: ## Run tests
	forge test

build: ## Build contracts
	forge build

fmt-check: ## Check code format
	forge fmt --check

fmt: ## Format code
	forge fmt

anvil: ## Start local anvil
	anvil

deploy-local: ## Deploy beacon + factory to local anvil
	forge script script/DeployVault.s.sol:DeployBeaconScript \
		--rpc-url local \
		--broadcast -vvvv

deploy-sepolia: ## Deploy beacon + factory to Sepolia
	forge script script/DeployVault.s.sol:DeployBeaconScript \
		--rpc-url sepolia \
		--broadcast \
		--verify -vvvv

deploy-mainnet: ## Deploy beacon + factory to Mainnet
	forge script script/DeployVault.s.sol:DeployBeaconScript \
		--rpc-url mainnet \
		--broadcast \
		--verify -vvvv

upgrade-local: ## Upgrade beacon implementation to VaultV2 on local anvil (requires BEACON)
	forge script script/UpgradeVault.s.sol:UpgradeBeaconScript \
		--rpc-url local \
		--broadcast -vvvv

upgrade-sepolia: ## Upgrade beacon implementation to VaultV2 on Sepolia (requires BEACON)
	forge script script/UpgradeVault.s.sol:UpgradeBeaconScript \
		--rpc-url sepolia \
		--broadcast \
		--verify -vvvv

upgrade-mainnet: ## Upgrade beacon implementation to VaultV2 on Mainnet (requires BEACON)
	forge script script/UpgradeVault.s.sol:UpgradeBeaconScript \
		--rpc-url mainnet \
		--broadcast \
		--verify -vvvv
