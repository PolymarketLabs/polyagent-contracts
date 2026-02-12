.DEFAULT_GOAL := help
.PHONY: help test build fmt-check fmt anvil \
	deploy-vault-local deploy-vault-sepolia deploy-vault-mainnet \
	deploy-factory-local deploy-factory-sepolia deploy-factory-mainnet \
	upgrade-local upgrade-sepolia upgrade-mainnet

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

deploy-vault-local: ## Deploy Vault beacon to local anvil
	forge script script/DeployVault.s.sol:DeployVaultScript \
		--rpc-url local \
		--broadcast -vvvv

deploy-vault-sepolia: ## Deploy Vault beacon to Sepolia
	forge script script/DeployVault.s.sol:DeployVaultScript \
		--rpc-url sepolia \
		--broadcast \
		--verify -vvvv

deploy-vault-mainnet: ## Deploy Vault beacon to Mainnet
	forge script script/DeployVault.s.sol:DeployVaultScript \
		--rpc-url mainnet \
		--broadcast \
		--verify -vvvv

deploy-factory-local: ## Deploy VaultFactory proxy to local anvil (requires BEACON)
	forge script script/DeployVaultFactory.s.sol:DeployVaultFactoryScript \
		--rpc-url local \
		--broadcast -vvvv

deploy-factory-sepolia: ## Deploy VaultFactory proxy to Sepolia (requires BEACON)
	forge script script/DeployVaultFactory.s.sol:DeployVaultFactoryScript \
		--rpc-url sepolia \
		--broadcast \
		--verify -vvvv

deploy-factory-mainnet: ## Deploy VaultFactory proxy to Mainnet (requires BEACON)
	forge script script/DeployVaultFactory.s.sol:DeployVaultFactoryScript \
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
