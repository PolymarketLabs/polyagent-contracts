# 测试与部署指南

本文档用于指导开发人员在本地与测试网/主网（含 Polygon）执行合约测试、部署与升级。

## 1. 前置要求

1. 已安装 Foundry（`forge`、`cast`、`anvil`）。
2. 已拉取项目依赖（`lib/` 已存在）。
3. 使用与 `UpgradeableBeacon` owner 对应的私钥执行部署/升级。

可快速检查工具版本：

```bash
forge --version
anvil --version
```

## 2. 环境变量配置

1. 复制模板文件：

```bash
cp .env-example .env
```

2. 在 `.env` 中填写以下变量：

```dotenv
PRIVATE_KEY=
LOCAL_RPC_URL=http://127.0.0.1:8545
SEPOLIA_RPC_URL=
MAINNET_RPC_URL=
POLYGON_AMOY_RPC_URL=
POLYGON_MAINNET_RPC_URL=
ETHERSCAN_API_KEY=
BEACON=
FACTORY_PROXY=
```

变量说明：

1. `PRIVATE_KEY`：广播交易账户私钥（部署与升级都会使用）。
2. `LOCAL_RPC_URL` / `SEPOLIA_RPC_URL` / `MAINNET_RPC_URL` / `POLYGON_AMOY_RPC_URL` / `POLYGON_MAINNET_RPC_URL`：对应网络 RPC。
3. `ETHERSCAN_API_KEY`：仅 `--verify` 时需要。
4. `BEACON`：部署 Factory 与升级 Vault 时使用的 Beacon 地址。
5. `FACTORY_PROXY`：升级 VaultFactory 时使用的代理地址。

执行命令前，先加载环境变量：

```bash
source .env
```

## 3. 本地测试

运行全部测试：

```bash
make test
```

或直接：

```bash
forge test --offline
```

编译与格式化检查：

```bash
make build
make fmt-check
```

## 4. 本地部署（Anvil）

1. 启动本地链（终端 A）：

```bash
make anvil
```

2. 准备 `.env`（终端 B）：

1. `LOCAL_RPC_URL=http://127.0.0.1:8545`
2. `PRIVATE_KEY` 填 Anvil 默认账户私钥之一

3. 执行部署（终端 B）：

```bash
source .env
make deploy-vault-local
```

部署脚本：`script/DeployVault.s.sol:DeployVaultScript`  
输出会打印：

1. `beacon: <address>`
2. `vault implementation: <address>`

4. 将上一步输出的 `beacon` 写回 `.env`：

```dotenv
BEACON=<vault beacon address>
```

5. 部署 Factory 代理：

```bash
source .env
make deploy-factory-local
```

部署脚本：`script/DeployVaultFactory.s.sol:DeployVaultFactoryScript`  
输出会打印：

1. `beacon: <address>`
2. `factory implementation: <address>`
3. `factory proxy: <address>`

## 5. 测试网/主网部署

Sepolia：

```bash
source .env
make deploy-vault-sepolia
# 将输出的 beacon 地址写入 .env 的 BEACON
make deploy-factory-sepolia
```

Mainnet：

```bash
source .env
make deploy-vault-mainnet
# 将输出的 beacon 地址写入 .env 的 BEACON
make deploy-factory-mainnet
```

Polygon Amoy：

```bash
source .env
make deploy-vault-polygon-amoy
# 将输出的 beacon 地址写入 .env 的 BEACON
make deploy-factory-polygon-amoy
```

Polygon Mainnet：

```bash
source .env
make deploy-vault-polygon-mainnet
# 将输出的 beacon 地址写入 .env 的 BEACON
make deploy-factory-polygon-mainnet
```

说明：

1. 上述命令包含 `--verify`，需要 `ETHERSCAN_API_KEY`。
2. 广播账户余额需覆盖部署 gas 成本。

## 6. 升级流程

### 6.1 Vault 升级（Beacon -> VaultV2）

升级脚本：`script/UpgradeVault.s.sol:UpgradeVaultScript`  
脚本行为：

1. 部署新的 `VaultV2` 实现合约。
2. 调用 `UpgradeableBeacon.upgradeTo(newImplementation)` 完成升级。

升级前准备：

1. 设置 `.env` 中 `BEACON=<部署得到的 beacon 地址>`。
2. 确认 `PRIVATE_KEY` 对应账户是该 Beacon 的 owner。

本地升级：

```bash
source .env
make upgrade-vault-local
```

Sepolia 升级：

```bash
source .env
make upgrade-vault-sepolia
```

Mainnet 升级：

```bash
source .env
make upgrade-vault-mainnet
```

Polygon Amoy 升级：

```bash
source .env
make upgrade-vault-polygon-amoy
```

Polygon Mainnet 升级：

```bash
source .env
make upgrade-vault-polygon-mainnet
```

升级后建议验证：

1. `beacon.implementation()` 是否指向新实现。
2. 关键状态（例如 `baseAsset`、`admin`、`operator`）是否保持不变。
3. 通过代理调用 `initializeV2` 后，`initializedVersion()` 从 `1` 变为 `2`。

### 6.2 VaultFactory 升级（UUPS -> VaultFactoryV2）

升级脚本：`script/UpgradeVaultFactory.s.sol:UpgradeVaultFactoryScript`  
脚本行为：

1. 部署新的 `VaultFactoryV2` 实现合约。
2. 对 `FACTORY_PROXY` 执行 `upgradeToAndCall`，并调用 `initializeV2`。

升级前准备：

1. 设置 `.env` 中 `FACTORY_PROXY=<部署得到的 factory proxy 地址>`。
2. 确认 `PRIVATE_KEY` 对应账户是 Factory owner。

本地升级：

```bash
source .env
make upgrade-factory-local
```

Sepolia 升级：

```bash
source .env
make upgrade-factory-sepolia
```

Mainnet 升级：

```bash
source .env
make upgrade-factory-mainnet
```

Polygon Amoy 升级：

```bash
source .env
make upgrade-factory-polygon-amoy
```

Polygon Mainnet 升级：

```bash
source .env
make upgrade-factory-polygon-mainnet
```

## 7. 常见问题

1. 报错 `OwnableUnauthorizedAccount`：当前私钥不是 Beacon owner。
2. 报错缺少 RPC：检查 `.env` 和 `source .env` 是否已生效。
3. 验证失败：检查 `ETHERSCAN_API_KEY` 与网络是否匹配。
4. 升级脚本报 `BEACON` 未设置：补充 `.env` 中 `BEACON=...`。
5. 升级 Factory 报 `FACTORY_PROXY` 未设置：补充 `.env` 中 `FACTORY_PROXY=...`。
6. Polygon 网络部署报 `Insufficient funds`：Polygon 链上 gas token 是 `POL`，需确保广播账户有足够 `POL` 支付 gas。
