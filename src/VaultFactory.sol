// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {Fund} from "./factory/VaultFactoryTypes.sol";
import {VaultFactoryEvents} from "./factory/VaultFactoryEvents.sol";
import {VaultFactoryErrors} from "./factory/VaultFactoryErrors.sol";

contract VaultFactory is Ownable, IVaultFactory, VaultFactoryEvents, VaultFactoryErrors {
    // ===== 核心配置 =====
    UpgradeableBeacon public immutable BEACON; // Beacon 合约地址（统一管理 Vault 实现）

    // ===== 基金索引 =====
    uint256 public nextFundId = 1; // 下一个可分配的基金 ID（从 1 开始）
    mapping(uint256 => Fund) public funds; // fundId => 基金元信息
    mapping(address => uint256) public fundIds; // vault 地址 => fundId

    constructor(address beacon, address initialOwner) Ownable(initialOwner) {
        if (beacon == address(0)) revert ZeroAddress();

        // 校验 beacon 地址有效：可读取 implementation 且实现地址非零。
        try UpgradeableBeacon(beacon).implementation() returns (address implementation) {
            if (implementation == address(0)) revert InvalidBeacon();
        } catch {
            revert InvalidBeacon();
        }

        BEACON = UpgradeableBeacon(beacon);
    }

    // ===== 基金创建 =====
    function createFund(
        string memory tokenName,
        string memory tokenSymbol,
        address baseAsset,
        address manager,
        address admin,
        address operator,
        address executor,
        uint256 secondsPerEpoch
    ) external override onlyOwner returns (address vault) {
        if (address(0) == manager) revert ZeroAddress();
        bytes memory initData = abi.encodeCall(
            IVault.initialize, (tokenName, tokenSymbol, baseAsset, admin, operator, executor, secondsPerEpoch)
        );

        vault = address(new BeaconProxy(address(BEACON), initData));

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

        emit FundCreated(vault, baseAsset, manager, admin, operator, executor, block.timestamp, fundId);
    }

    // ===== 只读查询 =====
    function totalFunds() external view override returns (uint256) {
        return nextFundId - 1;
    }
}
