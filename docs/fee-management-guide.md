# 费用管理设计规范

本文档是费用系统的开发指导规范，重点说明概念、功能边界、业务规则和实现逻辑。
目标是让任何开发者在不依赖历史上下文的情况下，按统一口径实现、测试和审计费用模块。

---

## 1. 范围与目标

费用模块覆盖以下能力：

1. 费用策略配置与按阶段生效。
2. 申购、赎回、管理费、业绩费的计算口径。
3. 平台、推荐人、基金经理三方分配。
4. 应计与领取分离（`accrual + claim`）。
5. 推荐关系绑定与约束。

设计目标：

1. 可审计：每个阶段使用哪套策略可追踪。
2. 可对账：费用来源、分配、领取三账一致。
3. 可治理：策略变更可控且可回溯。
4. 可扩展：新增费种或分账规则不破坏现有数据。

---

## 2. 核心概念

1. `FeeType`
定义费用类别：`ENTRY`、`EXIT`、`MGMT`、`PERFORMANCE`。

2. `FeePolicy`
一个“收费阶段”的完整快照，包含：
- 全部费率
- 全部费种分账比例
- 收款地址配置

3. `FeePolicyCheckpoint`
表示“从某个 epoch 开始启用哪份 FeePolicy”。

4. `effectiveEpoch`
策略生效时间边界，所有费用计算都按业务事件归属 epoch 选择策略。

5. `feeClaimable`
收款方可领取余额账本，只记账，不在结算主流程中直接打款。

6. `referrer`
用户一级推荐关系，仅用于可分配给推荐人的费种。

---

## 3. 费用归属规则

业务归属固定如下：

1. `ENTRY`：平台 + 推荐人 + 基金经理按比例分配。
2. `EXIT`：平台 + 基金经理按比例分配，推荐人比例固定为 0。
3. `MGMT`：基金经理独享。
4. `PERFORMANCE`：基金经理独享。

当用户无推荐人时：

1. 推荐人份额必须有确定去向。
2. 推荐人份额必须回流至预先配置的固定地址（`platform` 或 `reserve`）。
3. 必须在产品规则与文档中固定，不允许运行时歧义。

---

## 4. 费用计算逻辑（口径）

### 4.1 申购费（ENTRY）

```text
entryFee = depositAmount * entryFeeBps / 10_000
netDeposit = depositAmount - entryFee
```

1. `netDeposit` 进入后续份额计算口径。
2. `entryFee` 进入费用分账流程。

### 4.2 赎回费（EXIT）

```text
exitFee = grossRedeemAssets * exitFeeBps / 10_000
netRedeemAssets = grossRedeemAssets - exitFee
```

1. 用户实际可领取为 `netRedeemAssets`。
2. `exitFee` 进入费用分账流程。

### 4.3 管理费（MGMT）

```text
mgmtFee = totalAum * mgmtFeeAnnualBps * secondsPerEpoch / (365 days * 10_000)
```

在封账阶段计提。

### 4.4 业绩费（PERFORMANCE）

采用 HWM（High Water Mark）模型：

```text
excessNav = max(navPerShare - highWaterMarkNav, 0)
performanceBase = excessNav * sharesAtSettle
performanceFee = performanceBase * performanceFeeBps / 10_000
```

规则：

1. 仅当 `navPerShare` 高于 HWM 时收取。
2. 收取后更新 HWM。

### 4.5 舍入规则

必须在全系统固定舍入方向（统一向下取整），并在测试中覆盖边界值。

---

## 5. 分账与记账模型

流程如下：

1. 先算总费用。
2. 按费种对应分账比例拆分到三方金额。
3. 将金额累加到 `feeClaimable[recipient]`。
4. 收款方通过 `claimFee` 主动领取。

禁止在批处理结算流程中直接向外部地址转账，避免外部调用导致流程阻塞或可用性下降。

---

## 6. 推荐关系模型

推荐关系采用“首绑确认”机制：

1. 未绑定用户首次可绑定推荐人。
2. 已绑定后不可变更（除非有明确治理流程）。
3. 禁止自荐。
4. 禁止互荐（A 推荐 B 后，B 不能再推荐 A）。
5. 允许空推荐人（无推荐关系）。

---

## 7. Epoch 与策略生效逻辑

费用系统必须与 epoch 流程对齐，规则如下：

1. 每笔业务按其归属 epoch 决定策略。
2. 结算时应明确“读取哪个 checkpoint”。
3. 同一笔业务在整个生命周期内不应跨策略重算。
