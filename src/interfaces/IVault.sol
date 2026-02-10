// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

interface IVault {
    function initialize(
        string memory tokenName,
        string memory tokenSymbol,
        address _baseAsset,
        address _admin,
        address _operator,
        address _executor,
        uint256 _secondsPerEpoch
    ) external;

    function requestDeposit(uint256 amount) external returns (uint256 epoch, uint256 index);
    function requestRedeem(uint256 shares) external returns (uint256 epoch, uint256 index);
    function cancelDeposit(uint256 epoch, uint256 index) external;
    function cancelRedeem(uint256 epoch, uint256 index) external;
    function claim(address to) external returns (uint256 amount);

    function finalizeEpoch(uint256 epoch, uint256 totalAum) external;
    function settleDeposits(uint256 epoch, uint256 maxCount) external;
    function settleRedeems(uint256 epoch, uint256 maxCount) external;
    function transferToExecutor(uint256 amount) external;

    function pauseDeposit() external;
    function unpauseDeposit() external;
    function pauseRedeem() external;
    function unpauseRedeem() external;

    function currentEpoch() external view returns (uint256);
    function initializedVersion() external view returns (uint64);
    function depositRequestCount(uint256 epoch) external view returns (uint256);
    function redeemRequestCount(uint256 epoch) external view returns (uint256);
}
