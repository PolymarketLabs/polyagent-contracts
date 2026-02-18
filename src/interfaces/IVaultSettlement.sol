// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

interface IVaultSettlement {
    struct EpochSnapshot {
        uint256 totalAum;
        uint256 sharesAtSettle;
        uint256 navPerShare;
        uint256 finalizedAt;
    }

    struct SettlementCursor {
        uint256 nextIndex;
        bool done;
    }

    event EpochFinalized(uint256 indexed epoch, uint256 totalAum, uint256 sharesAtSettle, uint256 navPerShare);
    event DepositSettled(uint256 indexed epoch, uint256 indexed index, address indexed investor, uint256 shares);
    event RedeemSettled(uint256 indexed epoch, uint256 indexed index, address indexed investor, uint256 amount);

    // write functions
    function finalizeEpoch(uint256 epoch, uint256 totalAum) external;

    function settleDeposits(uint256 epoch, uint256 maxCount) external;

    function settleRedeems(uint256 epoch, uint256 maxCount) external;

    // read functions
    function lastFinalizedEpoch() external view returns (uint256);

    function snapshotOf(uint256 epoch) external view returns (EpochSnapshot memory snapshot);

    function depositCursorOf(uint256 epoch) external view returns (SettlementCursor memory cursor);

    function redeemCursorOf(uint256 epoch) external view returns (SettlementCursor memory cursor);
}
