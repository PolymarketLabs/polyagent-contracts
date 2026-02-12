// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Vault} from "../../src/Vault.sol";
import {VaultFactory} from "../../src/VaultFactory.sol";
import {VaultFactoryV2} from "../../src/VaultFactoryV2.sol";
import {USDC} from "../mocks/USDC.sol";

contract VaultFactoryUpgradeTest is Test {
    uint256 public constant SECONDS_PER_EPOCH = 86400;

    USDC public usdc;
    UpgradeableBeacon public beacon;
    VaultFactory public factory;

    address beaconOwner = makeAddr("beaconOwner");
    address factoryOwner = makeAddr("factoryOwner");
    address manager = makeAddr("manager");
    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address executor = makeAddr("executor");
    address outsider = makeAddr("outsider");

    function setUp() public {
        usdc = new USDC();
        Vault vaultImplementation = new Vault();
        beacon = new UpgradeableBeacon(address(vaultImplementation), beaconOwner);

        VaultFactory factoryImplementation = new VaultFactory();
        bytes memory initData = abi.encodeCall(VaultFactory.initialize, (address(beacon), factoryOwner));
        factory = VaultFactory(address(new ERC1967Proxy(address(factoryImplementation), initData)));
    }

    /// @notice 非 owner 调用升级应回滚
    function test_upgradeToAndCall_reverts_whenCallerIsNotOwner() public {
        VaultFactoryV2 implementationV2 = new VaultFactoryV2();

        vm.prank(outsider);
        vm.expectRevert();
        factory.upgradeToAndCall(address(implementationV2), bytes(""));
    }

    /// @notice 升级到 V2 后应保持原有状态，并将 initializedVersion 从 1 提升到 2
    function test_upgradeToV2_preservesState_and_updatesInitializedVersion() public {
        vm.prank(factoryOwner);
        address vaultAddr = factory.createFund(
            "Alpha Fund Share", "AFS", address(usdc), manager, admin, operator, executor, SECONDS_PER_EPOCH
        );
        assertEq(factory.initializedVersion(), 1);
        assertEq(factory.totalFunds(), 1);
        assertEq(factory.fundIds(vaultAddr), 1);

        VaultFactoryV2 implementationV2 = new VaultFactoryV2();
        bytes memory initV2Data = abi.encodeCall(VaultFactoryV2.initializeV2, ());
        vm.prank(factoryOwner);
        factory.upgradeToAndCall(address(implementationV2), initV2Data);

        VaultFactoryV2 upgraded = VaultFactoryV2(address(factory));
        assertEq(upgraded.initializedVersion(), 2);
        assertEq(upgraded.totalFunds(), 1);
        assertEq(upgraded.fundIds(vaultAddr), 1);

        (
            address fundVault,
            address fundBaseAsset,
            address fundManager,
            address fundAdmin,
            address fundOperator,
            address fundExecutor,
            uint256 fundCreatedAt
        ) = upgraded.funds(1);
        assertEq(fundVault, vaultAddr);
        assertEq(fundBaseAsset, address(usdc));
        assertEq(fundManager, manager);
        assertEq(fundAdmin, admin);
        assertEq(fundOperator, operator);
        assertEq(fundExecutor, executor);
        assertTrue(fundCreatedAt > 0);
    }

    /// @notice initializeV2 只允许执行一次
    function test_initializeV2_reverts_whenCalledTwice() public {
        VaultFactoryV2 implementationV2 = new VaultFactoryV2();
        bytes memory initV2Data = abi.encodeCall(VaultFactoryV2.initializeV2, ());
        vm.prank(factoryOwner);
        factory.upgradeToAndCall(address(implementationV2), initV2Data);

        VaultFactoryV2 upgraded = VaultFactoryV2(address(factory));
        assertEq(upgraded.initializedVersion(), 2);

        vm.prank(factoryOwner);
        vm.expectRevert();
        upgraded.initializeV2();
    }
}
