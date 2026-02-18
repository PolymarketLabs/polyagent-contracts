// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {VaultFee} from "./VaultFee.sol";
import {NavLib} from "./VaultLib.sol";
import {IVaultSettlement} from "./interfaces/IVaultSettlement.sol";

abstract contract VaultSettlement is VaultFee, IVaultSettlement {
    struct VaultSettlementStorage {
        mapping(uint256 => EpochSnapshot) snapshots;
        mapping(uint256 => SettlementCursor) depositCursors;
        mapping(uint256 => SettlementCursor) redeemCursors;
        uint256 lastFinalizedEpoch;
    }

    bytes32 private constant SETTLEMENT_STORAGE_LOCATION = keccak256("polyagent.vault.settlement.v1");

    error InvalidFinalizeEpoch();
    error InvalidMaxCount();
    error InvalidTotalAum();
    error InvalidChargedFee();
    error DepositsSettlementCompleted();
    error RedeemsSettlementCompleted();

    function _vaultSettlementStorage() internal pure returns (VaultSettlementStorage storage $) {
        bytes32 slot = SETTLEMENT_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    // write functions
    function finalizeEpoch(uint256 epoch, uint256 totalAum)
        public
        virtual
        override
        nonReentrant
        onlyRole(OPERATOR_ROLE)
    {
        _validateFinalizeEpoch(epoch);

        VaultSettlementStorage storage $ = _vaultSettlementStorage();
        VaultUserStorage storage u = _vaultUserStorage();
        uint256 pricingAum = totalAum;
        uint256 epochNetDeposits = u.netRequestedDepositAssets[epoch];
        if (epochNetDeposits > 0) {
            if (pricingAum < epochNetDeposits) {
                revert InvalidTotalAum();
            }
            pricingAum -= epochNetDeposits;
        }

        uint256 sharesAtSettle = _sharesAtSettle();
        uint256 totalFee = _chargeEpochFees(epoch, pricingAum, sharesAtSettle, _deltaSeconds(epoch));
        if (totalFee > pricingAum) {
            revert InvalidChargedFee();
        }

        uint256 settledTotalAum = pricingAum - totalFee;
        uint256 navPerShare = NavLib.calcNavPerShare(settledTotalAum, sharesAtSettle);

        $.snapshots[epoch] = EpochSnapshot({
            totalAum: settledTotalAum,
            sharesAtSettle: sharesAtSettle,
            navPerShare: navPerShare,
            finalizedAt: block.timestamp
        });
        $.lastFinalizedEpoch = epoch;

        emit EpochFinalized(epoch, settledTotalAum, sharesAtSettle, navPerShare);
    }

    function settleDeposits(uint256 epoch, uint256 maxCount)
        public
        virtual
        override
        nonReentrant
        onlyRole(OPERATOR_ROLE)
    {
        if (maxCount == 0) {
            revert InvalidMaxCount();
        }

        VaultSettlementStorage storage $ = _vaultSettlementStorage();
        EpochSnapshot storage snapshot = $.snapshots[epoch];
        if (snapshot.finalizedAt == 0) {
            revert InvalidFinalizeEpoch();
        }

        SettlementCursor storage cursor = $.depositCursors[epoch];
        if (cursor.done) {
            revert DepositsSettlementCompleted();
        }

        VaultUserStorage storage u = _vaultUserStorage();
        DepositRequest[] storage requests = u.depositRequests[epoch];
        uint256 len = requests.length;
        uint256 start = cursor.nextIndex;
        if (start >= len) {
            cursor.done = true;
            return;
        }

        uint256 end = start + maxCount;
        if (end > len) {
            end = len;
        }

        if (snapshot.navPerShare == 0) {
            revert InvalidFinalizeEpoch();
        }

        for (uint256 i = start; i < end; i++) {
            DepositRequest storage req = requests[i];
            if (req.status != ReqStatus.Pending) {
                continue;
            }
            _settleDepositRequest(epoch, i, snapshot.navPerShare, req);
        }

        cursor.nextIndex = end;
        if (end == len) {
            cursor.done = true;
        }
    }

    function settleRedeems(uint256 epoch, uint256 maxCount)
        public
        virtual
        override
        nonReentrant
        onlyRole(OPERATOR_ROLE)
    {
        if (maxCount == 0) {
            revert InvalidMaxCount();
        }

        VaultSettlementStorage storage $ = _vaultSettlementStorage();
        EpochSnapshot storage snapshot = $.snapshots[epoch];
        if (snapshot.finalizedAt == 0) {
            revert InvalidFinalizeEpoch();
        }

        SettlementCursor storage cursor = $.redeemCursors[epoch];
        if (cursor.done) {
            revert RedeemsSettlementCompleted();
        }

        VaultUserStorage storage u = _vaultUserStorage();
        RedeemRequest[] storage requests = u.redeemRequests[epoch];
        uint256 len = requests.length;
        uint256 start = cursor.nextIndex;
        if (start >= len) {
            cursor.done = true;
            return;
        }

        uint256 end = start + maxCount;
        if (end > len) {
            end = len;
        }

        if (snapshot.navPerShare == 0) {
            revert InvalidFinalizeEpoch();
        }

        for (uint256 i = start; i < end; i++) {
            RedeemRequest storage req = requests[i];
            if (req.status != ReqStatus.Pending) {
                continue;
            }
            _settleRedeemRequest(epoch, i, snapshot.navPerShare, u, req);
        }

        cursor.nextIndex = end;
        if (end == len) {
            cursor.done = true;
        }
    }

    // read functions
    function lastFinalizedEpoch() external view override returns (uint256) {
        return _vaultSettlementStorage().lastFinalizedEpoch;
    }

    function snapshotOf(uint256 epoch) external view override returns (EpochSnapshot memory snapshot) {
        return _vaultSettlementStorage().snapshots[epoch];
    }

    function depositCursorOf(uint256 epoch) external view override returns (SettlementCursor memory cursor) {
        return _vaultSettlementStorage().depositCursors[epoch];
    }

    function redeemCursorOf(uint256 epoch) external view override returns (SettlementCursor memory cursor) {
        return _vaultSettlementStorage().redeemCursors[epoch];
    }

    // internal functions
    function _settleDepositRequest(uint256 epoch, uint256 index, uint256 navPerShare, DepositRequest storage req)
        internal
    {
        uint256 chargedFee = _chargeEntryFee(epoch, req.investor, req.amount);
        if (chargedFee > req.amount) {
            revert InvalidChargedFee();
        }

        uint256 netAmount = req.amount - chargedFee;
        uint256 shares = NavLib.calcSharesForAssets(netAmount, navPerShare);
        req.status = ReqStatus.Settled;
        _mintShares(req.investor, shares);

        emit DepositSettled(epoch, index, req.investor, shares);
    }

    function _settleRedeemRequest(
        uint256 epoch,
        uint256 index,
        uint256 navPerShare,
        VaultUserStorage storage u,
        RedeemRequest storage req
    ) internal {
        uint256 grossAssets = NavLib.calcAssetsForShares(req.shares, navPerShare);
        uint256 chargedFee = _chargeExitFee(epoch, req.investor, grossAssets);
        if (chargedFee > grossAssets) {
            revert InvalidChargedFee();
        }

        uint256 assets = grossAssets - chargedFee;
        req.status = ReqStatus.Settled;
        _burnShares(address(this), req.shares);
        u.claimableAssets[req.investor] += assets;

        emit RedeemSettled(epoch, index, req.investor, assets);
    }

    function _deltaSeconds(uint256 epoch) internal view returns (uint256) {
        VaultSettlementStorage storage $ = _vaultSettlementStorage();
        uint256 deltaEpochs = $.lastFinalizedEpoch == 0 ? epoch - epoch0() : epoch - $.lastFinalizedEpoch;
        return deltaEpochs * secondsPerEpoch();
    }

    function _validateFinalizeEpoch(uint256 epoch) internal view {
        VaultSettlementStorage storage $ = _vaultSettlementStorage();
        uint256 current = _currentEpoch();
        if (epoch < epoch0()) {
            revert InvalidFinalizeEpoch();
        }
        if (epoch >= current) {
            revert InvalidFinalizeEpoch();
        }
        if (epoch <= $.lastFinalizedEpoch) {
            revert InvalidFinalizeEpoch();
        }
        if ($.snapshots[epoch].finalizedAt != 0) {
            revert InvalidFinalizeEpoch();
        }
    }

    // hooks
    function _isEpochFinalized(uint256 epoch) internal view override returns (bool) {
        return _vaultSettlementStorage().snapshots[epoch].finalizedAt != 0;
    }

    function _sharesAtSettle() internal view virtual returns (uint256);

    function _mintShares(address to, uint256 shares) internal virtual;

    function _burnShares(address from, uint256 shares) internal virtual;
}
