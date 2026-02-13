// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

abstract contract VaultEvents {
    event DepositRequested(uint256 indexed epoch, uint256 indexed index, address indexed investor, uint256 amount);
    event RedeemRequested(uint256 indexed epoch, uint256 indexed index, address indexed investor, uint256 shares);

    event DepositCanceled(uint256 indexed epoch, uint256 indexed index, address indexed investor, uint256 amount);
    event RedeemCanceled(uint256 indexed epoch, uint256 indexed index, address indexed investor, uint256 shares);

    /// @notice 封账时触发
    event EpochFinalized(uint256 indexed epoch, uint256 totalAum, uint256 sharesAtSettle, uint256 navPerShare);

    event DepositSettled(uint256 indexed epoch, uint256 indexed index, address indexed investor, uint256 shares);
    event RedeemSettled(uint256 indexed epoch, uint256 indexed index, address indexed investor, uint256 amount);

    event Claimed(address indexed investor, address indexed to, uint256 amount);

    event FeePolicyScheduled(uint256 indexed checkpointIndex, uint256 indexed effectiveEpoch);
    event ReferrerBound(address indexed investor, address indexed referrer);
    event FeeClaimed(address indexed recipient, address indexed to, uint256 amount);

    event DepositPauseStatusUpdated(address indexed admin, bool paused);
    event RedeemPauseStatusUpdated(address indexed admin, bool paused);
}
