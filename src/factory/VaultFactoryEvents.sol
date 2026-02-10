// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

abstract contract VaultFactoryEvents {
    event FundCreated(
        address indexed vault,
        address indexed baseAsset,
        address indexed manager,
        address admin,
        address operator,
        address executor,
        uint256 createdAt,
        uint256 fundId
    );
}
