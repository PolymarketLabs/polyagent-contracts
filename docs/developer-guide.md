# polyagent-contracts 合约开发文档

## 1. 项目介绍

本项目实现了一个**基于时间分区（epoch）的链上基金 Vault 系统**，用于支持多基金实例的申购、赎回与净值结算。

系统目标是将**传统开放式基金（T 日申购、T+1 结算）**的运作模式，安全、透明地映射到链上，并具备以下特性：

* 明确的时间边界（epoch），避免时间套利
* 链下估值（AUM） + 链上结算（NAV）的职责分离
* 分批结算，防止 DoS 风险
* 可升级架构（Beacon Proxy）
* 多基金实例（Factory 创建）
* 完整的事件日志，支持链下对账与审计

系统不追求即时兑换，而强调**公平性、可验证性和长期可运营性**。

---

## 2. 核心概念

### 2.1 Epoch（时间分区）

* Epoch 是系统的最小结算时间单位，默认 **1 天**
* 使用 **UTC 时间**，计算方式为：

```text
epoch = floor(block.timestamp / secondsPerEpoch)
```

* `secondsPerEpoch = 86400`
* `epoch0` 为合约初始化时的时间锚点

**核心规则：**

* 所有用户请求根据交易上链时间自动归属到某个 epoch
* 一个 epoch 内的请求，只会在该 epoch 结束后结算
* 当前 epoch 永远不可结算

---

### 2.2 基础资产（Base Asset）

* 每个 Vault 绑定一个 ERC20 作为基础资产（如 USDC）
* 申购、赎回、AUM 均以该资产计价
* Vault 持有基础资产，并可按需划转至执行钱包

---

### 2.3 份额（Shares）

* Vault 合约继承 `ERC20Upgradeable`
* 每个 Vault 实例本身就是一个 **基金份额 Token**
* 份额代表投资人对基金资产的比例性所有权
* 精度为 18 decimals
* `name` / `symbol` 在 Vault 初始化时指定，每个基金可不同

---

### 2.4 结算（Settlement）

结算分为两个阶段：

1. **封账（Finalize）**

   * 目的是锁定结算口径
   * 计算并固化 NAV
   * 只能针对 epoch < currentEpoch
   * 每个 epoch 只能 finalize 一次

2. **结算执行（Settle）**

   * 按 NAV 处理申购 / 赎回请求
   * 支持分批执行
   * 必须在 finalize 之后
   * 使用游标防止重复结算

---

## 3. 调用流程（含流程图）

### 3.1 用户操作流程

#### 3.1.1 申购（Deposit）

```text
User
 ├─ approve(baseAsset)
 ├─ requestDeposit(amount)
 │    └─ 记录 Pending 请求（归属当前 epoch）
 │
 └─ 等待 epoch 结束
      └─ 结算后自动获得份额
```

**特点：**

* 申购时只转入资产，不立即铸造份额
* 实际份额数量由结算时的 NAV 决定

---

#### 3.1.2 赎回（Redeem）

```text
User
 ├─ requestRedeem(shares)
 │    └─ 锁定 / 扣减份额
 │
 └─ 等待 epoch 结束
      └─ 结算后生成 claimable 资产
           └─ claim(to)
```

**特点：**

* 赎回采用 Pull 模式（claim）
* 避免结算阶段直接转账失败导致阻塞

---

#### 3.1.3 撤销请求（Cancel）

* 仅允许撤销：

  * 未结算
  * 未 finalize 的请求
* 已封账的 epoch 不允许撤销

---

### 3.2 运营操作流程（Operator）

#### 3.2.1 每日结算流程（T+1）

```text
Off-chain System
 ├─ 计算 T 日 AUM
 │
Operator
 ├─ finalizeEpoch(T, totalAum)
 │    └─ 固化 NAV 与份额快照
 │
 ├─ settleDeposits(T, maxCount)  (可多次)
 ├─ settleRedeems(T, maxCount)   (可多次)
 │
 └─ cursor 显示完成
```

---

### 3.3 管理员操作（Admin）

* 分配 / 撤销角色
* 暂停或恢复申购、赎回
* 配置关键参数（如 executor）

---

## 4. 合约概述

### 4.1 拓扑结构

```text
                      ┌───────────────────────────┐
                      │     Vault Implementation  │  (逻辑合约 v1/v2)
                      └─────────────▲─────────────┘
                                    │
                      ┌─────────────┴─────────────┐
                      │     Upgradeable Beacon    │  (存 implementation 地址)
                      └─────────────▲─────────────┘
                                    │
             createFund()           │
┌───────────────┐   deploy proxy    │     ┌──────────────────┐
│  VaultFactory ├───────────────────┼────►│  Vault Proxy #1  │  (Fund A)
└───────────────┘                   │     └──────────────────┘
                                    │     ┌──────────────────┐
                                    ├────►│  Vault Proxy #2  │  (Fund B)
                                    │     └──────────────────┘
                                    │     ┌──────────────────┐
                                    └────►│  Vault Proxy #N  │  (Fund N)
                                          └──────────────────┘

```

---

### 4.2 合约列表与主要功能

#### Vault（核心合约）

* ERC20 份额管理
* 申购 / 赎回请求记录
* Epoch 快照与结算
* AccessControl 权限控制
* Claim 模式资产领取

---

#### VaultFactory

* 创建 Vault 代理实例（BeaconProxy）
* 初始化参数（name、symbol、角色、基础资产）
* 管理 fundId → vault 映射

---

#### UpgradeableBeacon

* 持有 Vault 实现地址
* 升级时影响所有 Vault 实例

---

## 6. 未来计划

以下为设计中预留或可扩展方向：

1. **多币种申购**

   * 不同 baseAsset
   * 汇率折算后统一结算

2. **管理费 / 业绩费模块**

   * 基于 epoch 或 AUM 计算
   * 独立 FeeModule

3. **更细粒度的权限拆分**

   * NAV Reporter
   * Emergency Pauser

4. **跨链部署**

   * 多链 Factory
   * 统一 fundId 体系

5. **增加滑点约束**

   * 申购和赎回时增加滑点约束，用于价格保护
   * 增加失败处理逻辑

5. **Intent 上链**

   * 基金经理的操作意图上链记录
   * 提升操作透明性，方便回放和审计
