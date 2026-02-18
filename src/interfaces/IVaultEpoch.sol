// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

interface IVaultEpoch {
    function secondsPerEpoch() external view returns (uint256);

    function epoch0() external view returns (uint256);

    function currentEpoch() external view returns (uint256);
}
