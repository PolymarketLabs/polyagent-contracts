// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

enum ReqStatus {
    Pending,
    Settled,
    Canceled,
    Failed
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
