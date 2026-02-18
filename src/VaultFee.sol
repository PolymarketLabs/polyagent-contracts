// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {VaultUser} from "./VaultUser.sol";
import {IVaultFee} from "./interfaces/IVaultFee.sol";
import {AddressLib} from "./VaultLib.sol";
import {NavLib} from "./VaultLib.sol";
import {FeeLib} from "./VaultLib.sol";

abstract contract VaultFee is VaultUser, IVaultFee {
    struct VaultFeeStorage {
        uint256 highWaterMarkNav;
        FeePolicyCheckpoint[] feePolicyCheckpoints;
        // epoch => fee policy checkpoint sequence (index+1). 0 means unset.
        mapping(uint256 => uint256) feePolicySeq;
        mapping(address => uint256) feeClaimable;
    }

    bytes32 private constant FEE_STORAGE_LOCATION = keccak256("polyagent.vault.fee.v1");

    error InvalidEffectiveEpoch();
    error FeePolicyNotFound();
    error FeePolicyNotFoundForEpoch();
    error InvalidFeeCharge();
    error NoClaimableFee();

    function _vaultFeeStorage() internal pure returns (VaultFeeStorage storage $) {
        bytes32 slot = FEE_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    // write functions
    function setFeePolicy(FeePolicy calldata policy, uint256 effectiveEpoch)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _validateFeePolicy(policy);

        uint256 current = _currentEpoch();
        if (effectiveEpoch < current) {
            revert InvalidEffectiveEpoch();
        }

        VaultFeeStorage storage $ = _vaultFeeStorage();
        uint256 len = $.feePolicyCheckpoints.length;
        if (len > 0 && effectiveEpoch <= $.feePolicyCheckpoints[len - 1].effectiveEpoch) {
            revert InvalidEffectiveEpoch();
        }

        $.feePolicyCheckpoints.push(FeePolicyCheckpoint({effectiveEpoch: effectiveEpoch, policy: policy}));
        emit FeePolicySet(len, effectiveEpoch);
    }

    function claimFee(address to) external override nonReentrant returns (uint256 amount) {
        AddressLib.requireNonZeroAddress(to);

        VaultFeeStorage storage $ = _vaultFeeStorage();
        address sender = _msgSender();
        amount = $.feeClaimable[sender];
        if (amount == 0) {
            revert NoClaimableFee();
        }

        $.feeClaimable[sender] = 0;
        _transferBaseAssetTo(to, amount);
        emit FeeClaimed(sender, to, amount);
    }

    // read functions
    function feeClaimable(address recipient) external view override returns (uint256) {
        return _vaultFeeStorage().feeClaimable[recipient];
    }

    function highWaterMarkNav() external view override returns (uint256) {
        return _vaultFeeStorage().highWaterMarkNav;
    }

    function feePolicySeq(uint256 epoch) external view override returns (uint256) {
        return _vaultFeeStorage().feePolicySeq[epoch];
    }

    function feePolicyCheckpointCount() external view override returns (uint256) {
        return _vaultFeeStorage().feePolicyCheckpoints.length;
    }

    function feePolicyCheckpointAt(uint256 index)
        external
        view
        override
        returns (FeePolicyCheckpoint memory checkpoint)
    {
        return _vaultFeeStorage().feePolicyCheckpoints[index];
    }

    // internal functions
    function _getOrCreateFeePolicyForEpoch(uint256 epoch) internal returns (FeePolicy storage policy) {
        VaultFeeStorage storage $ = _vaultFeeStorage();
        uint256 seq = $.feePolicySeq[epoch];
        if (seq == 0) {
            seq = _getFeePolicyIndexForEpoch(epoch) + 1;
            $.feePolicySeq[epoch] = seq;
        }
        policy = $.feePolicyCheckpoints[seq - 1].policy;
    }

    function _getFeePolicyIndexForEpoch(uint256 epoch) internal view returns (uint256 policyIndex) {
        VaultFeeStorage storage $ = _vaultFeeStorage();
        uint256 len = $.feePolicyCheckpoints.length;
        for (uint256 i = len; i > 0; i--) {
            if ($.feePolicyCheckpoints[i - 1].effectiveEpoch <= epoch) {
                return i - 1;
            }
        }
        revert FeePolicyNotFound();
    }

    function _getFeePolicyForEpoch(uint256 epoch) internal view returns (FeePolicy memory policy) {
        return _vaultFeeStorage().feePolicyCheckpoints[_getFeePolicyIndexForEpoch(epoch)].policy;
    }

    function _validateFeePolicy(FeePolicy calldata policy) internal pure {
        AddressLib.requireNonZeroAddress(policy.recipients.reserve);

        FeeLib.validateBps(policy.rates.entryFeeBps);
        FeeLib.validateBps(policy.rates.exitFeeBps);
        FeeLib.validateBps(policy.rates.mgmtFeeAnnualBps);
        FeeLib.validateBps(policy.rates.performanceFeeBps);

        FeeLib.validateSplit(policy.entrySplit.platformBps, policy.entrySplit.referrerBps, policy.entrySplit.managerBps);
        FeeLib.validateSplit(policy.exitSplit.platformBps, policy.exitSplit.referrerBps, policy.exitSplit.managerBps);
        FeeLib.validateSplit(policy.mgmtSplit.platformBps, policy.mgmtSplit.referrerBps, policy.mgmtSplit.managerBps);
        FeeLib.validateSplit(
            policy.performanceSplit.platformBps, policy.performanceSplit.referrerBps, policy.performanceSplit.managerBps
        );

        _validateRecipientsForActiveSplit(policy.recipients, policy.entrySplit, policy.rates.entryFeeBps);
        _validateRecipientsForActiveSplit(policy.recipients, policy.exitSplit, policy.rates.exitFeeBps);
        _validateRecipientsForActiveSplit(policy.recipients, policy.mgmtSplit, policy.rates.mgmtFeeAnnualBps);
        _validateRecipientsForActiveSplit(policy.recipients, policy.performanceSplit, policy.rates.performanceFeeBps);
    }

    function _validateRecipientsForActiveSplit(
        FeeRecipientConfig calldata recipients,
        SplitConfig calldata splitConfig,
        uint16 feeRateBps
    ) internal pure {
        if (feeRateBps == 0) {
            return;
        }

        if (splitConfig.platformBps > 0) {
            AddressLib.requireNonZeroAddress(recipients.platform);
        }
        if (splitConfig.managerBps > 0) {
            AddressLib.requireNonZeroAddress(recipients.manager);
        }
    }

    function _accrueFeeBySplit(
        FeeRecipientConfig storage recipients,
        SplitConfig storage splitConfig,
        address investor,
        uint256 fee
    ) internal {
        if (fee == 0) {
            return;
        }

        (uint256 platformAmount, uint256 referrerAmount, uint256 managerAmount, uint256 remainderAmount) =
            FeeLib.splitFee(fee, splitConfig.platformBps, splitConfig.referrerBps, splitConfig.managerBps);

        VaultUserStorage storage u = _vaultUserStorage();
        address platformRecipient = recipients.platform;
        address managerRecipient = recipients.manager;
        address reserveRecipient = recipients.reserve;
        address referrerRecipient = u.referrers[investor];
        if (referrerRecipient == address(0)) {
            referrerRecipient = reserveRecipient;
        }

        _accrueFee(platformRecipient, platformAmount);
        _accrueFee(referrerRecipient, referrerAmount);
        _accrueFee(managerRecipient, managerAmount);
        _accrueFee(reserveRecipient, remainderAmount);
    }

    function _updateHighWaterMark(uint256 pricingAum, uint256 sharesAtSettle) internal {
        if (sharesAtSettle == 0) {
            return;
        }

        VaultFeeStorage storage $ = _vaultFeeStorage();
        uint256 navPerShare = NavLib.calcNavPerShare(pricingAum, sharesAtSettle);
        if (navPerShare > $.highWaterMarkNav) {
            $.highWaterMarkNav = navPerShare;
        }
    }

    function _accrueFee(address recipient, uint256 amount) internal {
        if (recipient == address(0) || amount == 0) {
            return;
        }
        _vaultFeeStorage().feeClaimable[recipient] += amount;
    }

    // hooks
    function _chargeEpochFees(uint256 epoch, uint256 pricingAum, uint256 sharesAtSettle, uint256 deltaSeconds)
        internal
        virtual
        returns (uint256 totalFee)
    {
        uint256 mgmtFee = _chargeMgmtFees(epoch, pricingAum, deltaSeconds);
        if (mgmtFee > pricingAum) {
            revert InvalidFeeCharge();
        }

        uint256 aumAfterMgmt = pricingAum - mgmtFee;
        uint256 performanceFee = _chargePerformanceFees(epoch, aumAfterMgmt, sharesAtSettle);
        if (performanceFee > aumAfterMgmt) {
            revert InvalidFeeCharge();
        }

        totalFee = mgmtFee + performanceFee;
    }

    function _chargeMgmtFees(uint256 epoch, uint256 pricingAum, uint256 deltaSeconds)
        internal
        virtual
        returns (uint256 fee)
    {
        FeePolicy storage policy = _getOrCreateFeePolicyForEpoch(epoch);
        fee = FeeLib.calcMgmtFee(pricingAum, policy.rates.mgmtFeeAnnualBps, deltaSeconds);
        if (fee > pricingAum) {
            fee = pricingAum;
        }
        if (fee > 0) {
            _accrueFeeBySplit(policy.recipients, policy.mgmtSplit, address(0), fee);
        }
    }

    function _chargePerformanceFees(uint256 epoch, uint256 pricingAum, uint256 sharesAtSettle)
        internal
        virtual
        returns (uint256 fee)
    {
        FeePolicy storage policy = _getOrCreateFeePolicyForEpoch(epoch);
        fee = FeeLib.calcPerformanceFee(
            pricingAum, sharesAtSettle, policy.rates.performanceFeeBps, _vaultFeeStorage().highWaterMarkNav
        );
        if (fee > pricingAum) {
            fee = pricingAum;
        }
        if (fee > 0) {
            _accrueFeeBySplit(policy.recipients, policy.performanceSplit, address(0), fee);
        }
        _updateHighWaterMark(pricingAum - fee, sharesAtSettle);
    }

    function _chargeEntryFee(uint256 epoch, address investor, uint256 amount) internal virtual returns (uint256 fee) {
        VaultFeeStorage storage $ = _vaultFeeStorage();
        uint256 seq = $.feePolicySeq[epoch];
        if (seq == 0) {
            revert FeePolicyNotFoundForEpoch();
        }

        FeePolicy storage policy = $.feePolicyCheckpoints[seq - 1].policy;
        fee = FeeLib.calcFee(amount, policy.rates.entryFeeBps);
        if (fee > 0) {
            _accrueFeeBySplit(policy.recipients, policy.entrySplit, investor, fee);
        }
    }

    function _chargeExitFee(uint256 epoch, address investor, uint256 amount) internal virtual returns (uint256 fee) {
        VaultFeeStorage storage $ = _vaultFeeStorage();
        uint256 seq = $.feePolicySeq[epoch];
        if (seq == 0) {
            revert FeePolicyNotFoundForEpoch();
        }

        FeePolicy storage policy = $.feePolicyCheckpoints[seq - 1].policy;
        fee = FeeLib.calcFee(amount, policy.rates.exitFeeBps);
        if (fee > 0) {
            _accrueFeeBySplit(policy.recipients, policy.exitSplit, investor, fee);
        }
    }
}
