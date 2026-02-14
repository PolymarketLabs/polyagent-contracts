.DEFAULT_GOAL := help
.PHONY: help test build fmt-check fmt anvil \
	deploy-vault-local deploy-vault-polygon-amoy deploy-vault-polygon-mainnet \
	deploy-factory-local deploy-factory-polygon-amoy deploy-factory-polygon-mainnet \
	upgrade-vault-local upgrade-vault-polygon-amoy upgrade-vault-polygon-mainnet \
	upgrade-factory-local upgrade-factory-polygon-amoy upgrade-factory-polygon-mainnet

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

deploy-vault-polygon-amoy: ## Deploy Vault beacon to Polygon Amoy
	forge script script/DeployVault.s.sol:DeployVaultScript \
		--rpc-url polygon-amoy \
		--broadcast \
		--verify -vvvv

deploy-vault-polygon-mainnet: ## Deploy Vault beacon to Polygon Mainnet
	forge script script/DeployVault.s.sol:DeployVaultScript \
		--rpc-url polygon-mainnet \
		--broadcast \
		--verify -vvvv

deploy-factory-local: ## Deploy VaultFactory proxy to local anvil (requires BEACON)
	forge script script/DeployVaultFactory.s.sol:DeployVaultFactoryScript \
		--rpc-url local \
		--broadcast -vvvv

deploy-factory-polygon-amoy: ## Deploy VaultFactory proxy to Polygon Amoy (requires BEACON)
	forge script script/DeployVaultFactory.s.sol:DeployVaultFactoryScript \
		--rpc-url polygon-amoy \
		--broadcast \
		--verify -vvvv

deploy-factory-polygon-mainnet: ## Deploy VaultFactory proxy to Polygon Mainnet (requires BEACON)
	forge script script/DeployVaultFactory.s.sol:DeployVaultFactoryScript \
		--rpc-url polygon-mainnet \
		--broadcast \
		--verify -vvvv

upgrade-vault-local: ## Upgrade beacon implementation to VaultV2 on local anvil (requires BEACON)
	forge script script/UpgradeVault.s.sol:UpgradeVaultScript \
		--rpc-url local \
		--broadcast -vvvv

upgrade-vault-polygon-amoy: ## Upgrade beacon implementation to VaultV2 on Polygon Amoy (requires BEACON)
	forge script script/UpgradeVault.s.sol:UpgradeVaultScript \
		--rpc-url polygon-amoy \
		--broadcast \
		--verify -vvvv

upgrade-vault-polygon-mainnet: ## Upgrade beacon implementation to VaultV2 on Polygon Mainnet (requires BEACON)
	forge script script/UpgradeVault.s.sol:UpgradeVaultScript \
		--rpc-url polygon-mainnet \
		--broadcast \
		--verify -vvvv

upgrade-factory-local: ## Upgrade VaultFactory proxy implementation to VaultFactoryV2 on local anvil (requires FACTORY_PROXY)
	forge script script/UpgradeVaultFactory.s.sol:UpgradeVaultFactoryScript \
		--rpc-url local \
		--broadcast -vvvv

upgrade-factory-polygon-amoy: ## Upgrade VaultFactory proxy implementation to VaultFactoryV2 on Polygon Amoy (requires FACTORY_PROXY)
	forge script script/UpgradeVaultFactory.s.sol:UpgradeVaultFactoryScript \
		--rpc-url polygon-amoy \
		--broadcast \
		--verify -vvvv

upgrade-factory-polygon-mainnet: ## Upgrade VaultFactory proxy implementation to VaultFactoryV2 on Polygon Mainnet (requires FACTORY_PROXY)
	forge script script/UpgradeVaultFactory.s.sol:UpgradeVaultFactoryScript \
		--rpc-url polygon-mainnet \
		--broadcast \
		--verify -vvvv
