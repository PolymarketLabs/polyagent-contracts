# 测试与部署指南

本文档用于指导开发人员在本地与测试网/主网执行合约测试、部署与升级。

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
ETHERSCAN_API_KEY=
BEACON=
```

变量说明：

1. `PRIVATE_KEY`：广播交易账户私钥（部署与升级都会使用）。
2. `LOCAL_RPC_URL` / `SEPOLIA_RPC_URL` / `MAINNET_RPC_URL`：对应网络 RPC。
3. `ETHERSCAN_API_KEY`：仅 `--verify` 时需要。
4. `BEACON`：升级脚本使用的 Beacon 地址。

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
make deploy-local
```

部署脚本：`script/DeployVault.s.sol:DeployBeaconScript`  
输出会打印：

1. `beacon: <address>`
2. `factory: <address>`

## 5. 测试网/主网部署

Sepolia：

```bash
source .env
make deploy-sepolia
```

Mainnet：

```bash
source .env
make deploy-mainnet
```

说明：

1. 上述命令包含 `--verify`，需要 `ETHERSCAN_API_KEY`。
2. 广播账户余额需覆盖部署 gas 成本。

## 6. 升级流程（Beacon -> VaultV2）

升级脚本：`script/UpgradeVaultScript.s.sol:UpgradeBeaconScript`  
脚本行为：

1. 部署新的 `VaultV2` 实现合约。
2. 调用 `UpgradeableBeacon.upgradeTo(newImplementation)` 完成升级。

升级前准备：

1. 设置 `.env` 中 `BEACON=<部署得到的 beacon 地址>`。
2. 确认 `PRIVATE_KEY` 对应账户是该 Beacon 的 owner。

本地升级：

```bash
source .env
make upgrade-local
```

Sepolia 升级：

```bash
source .env
make upgrade-sepolia
```

Mainnet 升级：

```bash
source .env
make upgrade-mainnet
```

升级后建议验证：

1. `beacon.implementation()` 是否指向新实现。
2. 关键状态（例如 `baseAsset`、`admin`、`operator`）是否保持不变。
3. 通过代理调用 `initializeV2` 后，`initializedVersion()` 从 `1` 变为 `2`。

## 7. 常见问题

1. 报错 `OwnableUnauthorizedAccount`：当前私钥不是 Beacon owner。
2. 报错缺少 RPC：检查 `.env` 和 `source .env` 是否已生效。
3. 验证失败：检查 `ETHERSCAN_API_KEY` 与网络是否匹配。
4. 升级脚本报 `BEACON` 未设置：补充 `.env` 中 `BEACON=...`。

