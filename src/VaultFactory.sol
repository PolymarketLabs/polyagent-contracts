// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Vault} from "./Vault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

struct Fund {
    address vault;
    address baseAsset;
    address manager; // 基金经理，当前版本只记录信息，不参与其他验证与交互
    address admin;
    address operator;
    address executor;
    uint256 createdAt;
}

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

error ZeroAddress();
error InvalidBeacon();

contract VaultFactory is Ownable {
    UpgradeableBeacon public immutable BEACON; // UpgradeableBeacon 地址（全局一个）

    uint256 public nextFundId = 1; // fundId递增器
    mapping(uint256 => Fund) public funds; // fundId => meta
    mapping(address => uint256) public fundIds; // vault => fundId

    constructor(address beacon, address initialOwner) Ownable(initialOwner) {
        if (beacon == address(0)) revert ZeroAddress();

        // 校验传入地址确实可作为 beacon 使用（需可读取 implementation 且非零地址）。
        try UpgradeableBeacon(beacon).implementation() returns (address implementation) {
            if (implementation == address(0)) revert InvalidBeacon();
        } catch {
            revert InvalidBeacon();
        }

        BEACON = UpgradeableBeacon(beacon);
    }

    /// @return vault 生成的vault合约地址
    function createFund(
        string memory tokenName,
        string memory tokenSymbol,
        address baseAsset,
        address manager,
        address admin,
        address operator,
        address executor,
        uint256 secondsPerEpoch
    ) external onlyOwner returns (address vault) {
        // 1. check params
        if (address(0) == manager) revert ZeroAddress();
        // 2. encode initialize call data
        bytes memory initData = abi.encodeCall(
            Vault.initialize, (tokenName, tokenSymbol, baseAsset, admin, operator, executor, secondsPerEpoch)
        );

        // 3. deploy BeaconProxy
        vault = address(new BeaconProxy(address(BEACON), initData));

        // 4. register
        uint256 fundId = nextFundId++;
        funds[fundId] = Fund({
            vault: vault,
            baseAsset: baseAsset,
            manager: manager,
            admin: admin,
            operator: operator,
            executor: executor,
            createdAt: block.timestamp
        });
        fundIds[vault] = fundId;

        // 4. emit event
        emit FundCreated(vault, baseAsset, manager, admin, operator, executor, block.timestamp, fundId);
    }

    function fundCount() external view returns (uint256) {
        return nextFundId - 1;
    }
}
