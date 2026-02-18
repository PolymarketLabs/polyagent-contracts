// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

interface IVaultFee {
    struct FeeRateConfig {
        uint16 entryFeeBps;
        uint16 exitFeeBps;
        uint16 mgmtFeeAnnualBps;
        uint16 performanceFeeBps;
    }

    struct SplitConfig {
        uint16 platformBps;
        uint16 referrerBps;
        uint16 managerBps;
    }

    struct FeeRecipientConfig {
        address platform;
        address manager;
        address reserve;
    }

    struct FeePolicy {
        FeeRateConfig rates;
        SplitConfig entrySplit;
        SplitConfig exitSplit;
        SplitConfig mgmtSplit;
        SplitConfig performanceSplit;
        FeeRecipientConfig recipients;
    }

    struct FeePolicyCheckpoint {
        uint256 effectiveEpoch;
        FeePolicy policy;
    }

    event FeePolicySet(uint256 indexed checkpointIndex, uint256 indexed effectiveEpoch);
    event FeeClaimed(address indexed recipient, address indexed to, uint256 amount);

    // write functions
    function setFeePolicy(FeePolicy calldata policy, uint256 effectiveEpoch) external;

    function claimFee(address to) external returns (uint256 amount);

    // read functions
    function feeClaimable(address recipient) external view returns (uint256);

    function highWaterMarkNav() external view returns (uint256);

    function feePolicySeq(uint256 epoch) external view returns (uint256);

    function feePolicyCheckpointCount() external view returns (uint256);

    function feePolicyCheckpointAt(uint256 index) external view returns (FeePolicyCheckpoint memory checkpoint);
}
