// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

interface IVaultFactory {
    function createFund(
        string memory tokenName,
        string memory tokenSymbol,
        address baseAsset,
        address manager,
        address admin,
        address operator,
        address executor,
        uint256 secondsPerEpoch
    ) external returns (address vault);

    function fundCount() external view returns (uint256);
}
