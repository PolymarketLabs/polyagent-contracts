// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";

contract VaultFactory is Initializable, OwnableUpgradeable, UUPSUpgradeable, IVaultFactory {
    struct Fund {
        address vault;
        address baseAsset;
        address manager;
        uint256 createdAt;
    }

    error ZeroAddress();
    error InvalidBeacon();

    // ===== Core configuration =====
    UpgradeableBeacon public beacon; // Beacon contract address (manages the shared Vault implementation)

    // ===== Fund indexing =====
    uint256 public nextFundId; // Next fund ID to assign (starts from 1)
    mapping(uint256 => Fund) public funds; // fundId => fund metadata
    mapping(address => uint256) public fundIds; // vault address => fundId

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _beacon, address initialOwner) external initializer {
        __Ownable_init(initialOwner);

        if (_beacon == address(0)) revert ZeroAddress();
        // Validate beacon address: implementation() must be callable and non-zero.
        try UpgradeableBeacon(_beacon).implementation() returns (address implementation) {
            if (implementation == address(0)) revert InvalidBeacon();
        } catch {
            revert InvalidBeacon();
        }

        beacon = UpgradeableBeacon(_beacon);
        nextFundId = 1;
    }

    // ===== Fund creation =====
    function createFund(
        string memory tokenName,
        string memory tokenSymbol,
        address baseAsset,
        address manager,
        address admin,
        address operator,
        address executor,
        uint256 secondsPerEpoch,
        uint256 initialMinDepositAmount,
        uint256 initialMinRedeemShares
    ) external override onlyOwner returns (address vault) {
        if (address(0) == manager) revert ZeroAddress();
        bytes memory initData = abi.encodeCall(
            IVault.initialize,
            (
                tokenName,
                tokenSymbol,
                baseAsset,
                admin,
                operator,
                executor,
                secondsPerEpoch,
                initialMinDepositAmount,
                initialMinRedeemShares
            )
        );

        vault = address(new BeaconProxy(address(beacon), initData));

        uint256 fundId = nextFundId++;
        funds[fundId] = Fund({vault: vault, baseAsset: baseAsset, manager: manager, createdAt: block.timestamp});
        fundIds[vault] = fundId;

        emit FundCreated(vault, baseAsset, manager, block.timestamp, fundId);
    }

    // ===== Read functions =====
    function totalFunds() external view override returns (uint256) {
        return nextFundId - 1;
    }

    function initializedVersion() external view override returns (uint64) {
        return _getInitializedVersion();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
