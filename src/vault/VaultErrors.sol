// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

abstract contract VaultErrors {
    error ZeroAddress();
    error InvalidSecondsPerEpoch();
    /// @notice 申购/赎回输入金额低于最小阈值
    error AmountTooSmall();
    /// @notice 仅请求所属投资者可执行撤销
    error NotRequestOwner();
    /// @notice 请求状态不允许执行当前操作（例如已结算/已撤销）
    error InvalidRequestStatus();
    /// @notice 目标 epoch 已封账，不允许再撤销请求或重复封账
    error EpochAlreadyFinalized();
    /// @notice 封账目标 epoch 非历史 epoch（当前或未来）
    error InvalidFinalizeEpoch();
    error DepositPaused();
    error DepositNotPaused();
    error RedeemPaused();
    error RedeemNotPaused();
    error InvalidBps();
    error InvalidSplit();
    error ReferrerAlreadyBound();
    error SelfReferral();
    error CircularReferral();
    /// @notice 无可领取资产
    error NoClaimableAssets();
    error NoClaimableFee();
    error InvalidEffectiveEpoch();
    error FeePolicyNotFound();
}
