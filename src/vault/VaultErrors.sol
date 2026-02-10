// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

abstract contract VaultErrors {
    error ZeroAddress();
    error InvalidSecondsPerEpoch();
    error EnforcedDepositPause();
    error ExpectedDepositPause();
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
