// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

interface IVaultPausable {
    event DepositPauseStatusUpdated(address indexed admin, bool paused);
    event RedeemPauseStatusUpdated(address indexed admin, bool paused);

    // write functions
    function pauseDeposit() external;

    function unpauseDeposit() external;

    function pauseRedeem() external;

    function unpauseRedeem() external;

    // read functions
    function depositPaused() external view returns (bool);

    function redeemPaused() external view returns (bool);
}
