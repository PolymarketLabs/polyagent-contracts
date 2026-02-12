// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

abstract contract VaultErrors {
    error ZeroAddress();
    error InvalidSecondsPerEpoch();
    /// @notice 申购/赎回输入金额低于最小阈值
    error AmountTooSmall();
    error DepositPaused();
    error DepositNotPaused();
    error EnforcedRedeemPause();
    error ExpectedRedeemPause();
    error InvalidBps();
    error InvalidSplit();
    error ReferrerAlreadyBound();
    error SelfReferral();
    error CircularReferral();
    error NoClaimableFee();
    error InvalidEffectiveEpoch();
    error FeePolicyNotFound();
}
