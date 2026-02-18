// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library Constants {
    uint256 internal constant NAV_SCALE = 1e18;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
}

library AddressLib {
    error ZeroAddress();
    error NotContract();

    function requireNonZeroAddress(address account) internal pure {
        if (account == address(0)) {
            revert ZeroAddress();
        }
    }

    function requireContract(address account) internal view {
        requireNonZeroAddress(account);
        if (account.code.length == 0) {
            revert NotContract();
        }
    }
}

library NavLib {
    function calcNavPerShare(uint256 totalAum, uint256 shares) internal pure returns (uint256) {
        if (shares == 0) {
            return Constants.NAV_SCALE;
        }
        return Math.mulDiv(totalAum, Constants.NAV_SCALE, shares);
    }

    function calcSharesForAssets(uint256 assets, uint256 navPerShare) internal pure returns (uint256) {
        return Math.mulDiv(assets, Constants.NAV_SCALE, navPerShare);
    }

    function calcAssetsForShares(uint256 shares, uint256 navPerShare) internal pure returns (uint256) {
        return Math.mulDiv(shares, navPerShare, Constants.NAV_SCALE);
    }
}

library FeeLib {
    error InvalidBps();
    error InvalidSplit();

    function validateBps(uint16 bps) internal pure {
        if (bps > Constants.BPS_DENOMINATOR) {
            revert InvalidBps();
        }
    }

    function validateSplit(uint16 platformBps, uint16 referrerBps, uint16 managerBps) internal pure {
        validateBps(platformBps);
        validateBps(referrerBps);
        validateBps(managerBps);

        uint256 sum = uint256(platformBps) + uint256(referrerBps) + uint256(managerBps);
        if (sum > Constants.BPS_DENOMINATOR) {
            revert InvalidSplit();
        }
    }

    function calcFee(uint256 amount, uint16 feeBps) internal pure returns (uint256 fee) {
        if (feeBps == 0) {
            return 0;
        }
        return Math.mulDiv(amount, feeBps, Constants.BPS_DENOMINATOR);
    }

    function calcMgmtFee(uint256 pricingAum, uint16 mgmtFeeAnnualBps, uint256 deltaSeconds)
        internal
        pure
        returns (uint256 fee)
    {
        if (pricingAum == 0 || mgmtFeeAnnualBps == 0 || deltaSeconds == 0) {
            return 0;
        }
        uint256 annualBpsTimesDelta = uint256(mgmtFeeAnnualBps) * deltaSeconds;
        return Math.mulDiv(pricingAum, annualBpsTimesDelta, Constants.BPS_DENOMINATOR * Constants.SECONDS_PER_YEAR);
    }

    function calcPerformanceFee(
        uint256 pricingAum,
        uint256 sharesAtSettle,
        uint16 performanceFeeBps,
        uint256 highWaterMarkNav
    ) internal pure returns (uint256 fee) {
        if (pricingAum == 0 || sharesAtSettle == 0 || performanceFeeBps == 0 || highWaterMarkNav == 0) {
            return 0;
        }

        uint256 navPerShareBeforePerformanceFee = NavLib.calcNavPerShare(pricingAum, sharesAtSettle);
        if (navPerShareBeforePerformanceFee <= highWaterMarkNav) {
            return 0;
        }

        uint256 gainPerShare = navPerShareBeforePerformanceFee - highWaterMarkNav;
        uint256 gainAum = Math.mulDiv(gainPerShare, sharesAtSettle, Constants.NAV_SCALE);
        return Math.mulDiv(gainAum, performanceFeeBps, Constants.BPS_DENOMINATOR);
    }

    function splitFee(uint256 fee, uint16 platformBps, uint16 referrerBps, uint16 managerBps)
        internal
        pure
        returns (uint256 platformAmount, uint256 referrerAmount, uint256 managerAmount, uint256 remainderAmount)
    {
        if (fee == 0) {
            return (0, 0, 0, 0);
        }

        platformAmount = Math.mulDiv(fee, platformBps, Constants.BPS_DENOMINATOR);
        referrerAmount = Math.mulDiv(fee, referrerBps, Constants.BPS_DENOMINATOR);
        managerAmount = Math.mulDiv(fee, managerBps, Constants.BPS_DENOMINATOR);

        uint256 distributed = platformAmount + referrerAmount + managerAmount;
        remainderAmount = fee - distributed;
    }
}
