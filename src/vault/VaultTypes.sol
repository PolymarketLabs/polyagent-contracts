// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

enum ReqStatus {
    Pending,
    Settled,
    Canceled,
    Failed
}

enum FeeType {
    ENTRY, // 申购费
    EXIT, // 赎回费
    MGMT, // 管理费
    PERFORMANCE // 业绩报酬
}

/// @notice 各类费率配置（单位：bps，10000 = 100%）
struct FeeRateConfig {
    uint16 entryFeeBps; // 申购费率
    uint16 exitFeeBps; // 赎回费率
    uint16 mgmtFeeAnnualBps; // 年化管理费率
    uint16 performanceFeeBps; // 业绩报酬费率
}

/// @notice 单一费用类型的三方分账比例（单位：bps，通常要求总和=10000）
struct SplitConfig {
    uint16 platformBps; // 平台分成
    uint16 referrerBps; // 推荐人分成
    uint16 managerBps; // 基金经理分成
}

/// @notice 费用接收地址配置
struct FeeRecipientConfig {
    address platform; // 平台收款地址
    address manager; // 基金经理收款地址
    address reserve; // 兜底/暂存地址（未分配或异常场景）
}

/// @notice 单个收费阶段的完整策略快照
struct FeePolicy {
    FeeRateConfig rates; // 本阶段费率
    SplitConfig entrySplit; // 申购费分账
    SplitConfig exitSplit; // 赎回费分账
    SplitConfig mgmtSplit; // 管理费分账
    SplitConfig performanceSplit; // 业绩报酬分账
    FeeRecipientConfig recipients; // 本阶段收款地址
}

/// @notice 生效时间点与策略的对应关系
struct FeePolicyCheckpoint {
    uint256 effectiveEpoch; // 从该 epoch 起生效
    FeePolicy policy; // 对应完整费用策略
}

struct DepositRequest {
    address investor;
    uint256 amount;
    ReqStatus status;
    uint256 epoch; // 请求发起时的epoch
}

struct RedeemRequest {
    address investor;
    uint256 shares;
    ReqStatus status;
    uint256 epoch;
}

struct EpochSnapshot {
    uint256 totalAum; // 资产总值
    uint256 sharesAtSettle; // 结算口径下的总份额
    uint256 navPerShare; // 单位份额的净值
    uint256 finalizedAt; // 封账时间
}

struct SettlementCursor {
    uint256 nextDeposit; // 下一个要结算的 deposit index
    uint256 nextRedeem; // 下一个要结算的 redeem index
    bool depositsDone;
    bool redeemsDone;
}
