// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Vault} from "../../src/Vault.sol";
import {VaultV2} from "../../src/VaultV2.sol";
import {VaultFactory} from "../../src/VaultFactory.sol";
import {USDC} from "../mocks/USDC.sol";

contract VaultUpgradeTest is Test {
    uint256 public constant INITIAL_TIMESTAMP = 1767225600; // 2026-01-01 00:00:00 UTC
    uint256 public constant SECONDS_PER_EPOCH = 86400;

    USDC public usdc;
    UpgradeableBeacon public beacon;
    VaultFactory public factory;
    Vault public vault;

    address beaconOwner = makeAddr("beaconOwner");
    address factoryOwner = makeAddr("factoryOwner");
    address manager = makeAddr("manager");
    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address executor = makeAddr("executor");
    address outsider = makeAddr("outsider");

    function setUp() public {
        vm.warp(INITIAL_TIMESTAMP);

        usdc = new USDC();
        Vault implementationV1 = new Vault();
        beacon = new UpgradeableBeacon(address(implementationV1), beaconOwner);
        factory = new VaultFactory(address(beacon), factoryOwner);

        vm.prank(factoryOwner);
        address proxy = factory.createFund(
            "Alpha Fund Share", "AFS", address(usdc), manager, admin, operator, executor, SECONDS_PER_EPOCH
        );
        vault = Vault(proxy);
    }

    /// @notice 非 beacon owner 调用 upgradeTo 应回滚
    function test_upgradeBeacon_reverts_whenCallerIsNotBeaconOwner() public {
        VaultV2 implementationV2 = new VaultV2();

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        beacon.upgradeTo(address(implementationV2));
    }

    /// @notice 升级后应保持原有状态，并可通过 initializeV2 将 initializedVersion 从 1 提升到 2
    function test_upgradeBeacon_toV2_preservesState_and_updatesInitializedVersion() public {
        assertEq(vault.baseAsset(), address(usdc));
        assertEq(vault.admin(), admin);
        assertEq(vault.operator(), operator);
        assertEq(vault.executor(), executor);
        assertEq(vault.secondsPerEpoch(), SECONDS_PER_EPOCH);

        VaultV2 implementationV2 = new VaultV2();
        vm.prank(beaconOwner);
        beacon.upgradeTo(address(implementationV2));

        VaultV2 upgraded = VaultV2(address(vault));
        assertEq(upgraded.initializedVersion(), 1);

        vm.prank(admin);
        upgraded.initializeV2();

        assertEq(upgraded.initializedVersion(), 2);
        assertEq(upgraded.baseAsset(), address(usdc));
        assertEq(upgraded.admin(), admin);
        assertEq(upgraded.operator(), operator);
        assertEq(upgraded.executor(), executor);
        assertEq(upgraded.secondsPerEpoch(), SECONDS_PER_EPOCH);
    }

    /// @notice initializeV2 只能由 DEFAULT_ADMIN_ROLE 调用
    function test_initializeV2_reverts_whenCallerIsNotAdmin() public {
        VaultV2 implementationV2 = new VaultV2();
        vm.prank(beaconOwner);
        beacon.upgradeTo(address(implementationV2));

        VaultV2 upgraded = VaultV2(address(vault));
        vm.prank(outsider);
        vm.expectRevert();
        upgraded.initializeV2();
    }

    /// @notice initializeV2 只允许执行一次
    function test_initializeV2_reverts_whenCalledTwice() public {
        VaultV2 implementationV2 = new VaultV2();
        vm.prank(beaconOwner);
        beacon.upgradeTo(address(implementationV2));

        VaultV2 upgraded = VaultV2(address(vault));
        vm.prank(admin);
        upgraded.initializeV2();
        assertEq(upgraded.initializedVersion(), 2);

        vm.prank(admin);
        vm.expectRevert();
        upgraded.initializeV2();
    }
}
