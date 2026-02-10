// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../src/Vault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {FundCreated} from "../src/factory/VaultFactoryEvents.sol";
import {ZeroAddress, InvalidBeacon} from "../src/factory/VaultFactoryErrors.sol";
import {USDC} from "./mocks/USDC.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

contract VaultFactoryTest is Test {
    uint256 public constant SECONDS_PER_EPOCH = 86400;

    USDC public usdc;
    VaultFactory public factory;

    address owner = makeAddr("owner");
    address beaconOwner = makeAddr("beaconOwner");
    address manager = makeAddr("manager");
    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address executor = makeAddr("executor");
    address outsider = makeAddr("outsider");

    function setUp() public {
        usdc = new USDC();

        Vault implementation = new Vault();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(implementation), beaconOwner);

        factory = new VaultFactory(address(beacon), owner);
    }

    /// @notice 构造函数传入零地址 beacon 时应回滚
    function test_constructor_reverts_whenBeaconIsZeroAddress() public {
        vm.expectRevert(ZeroAddress.selector);
        new VaultFactory(address(0), owner);
    }

    /// @notice 构造函数传入无效 beacon 地址时应回滚
    function test_constructor_reverts_whenBeaconIsInvalid() public {
        vm.expectRevert(InvalidBeacon.selector);
        new VaultFactory(address(this), owner);
    }

    /// @notice 验证工厂 owner 在构造后初始化正确
    function test_owner_initialized_correctly() public view {
        assertEq(factory.owner(), owner);
    }

    /// @notice 非 owner 调用 createFund 时应回滚
    function test_createFund_reverts_whenCallerIsNotOwner() public {
        vm.prank(outsider);
        vm.expectRevert();
        factory.createFund(
            "Alpha Fund Share", "AFS", address(usdc), manager, admin, operator, executor, SECONDS_PER_EPOCH
        );
    }

    /// @notice manager 为零地址时 createFund 应回滚
    function test_createFund_reverts_whenManagerIsZero() public {
        vm.prank(owner);
        vm.expectRevert(ZeroAddress.selector);
        factory.createFund(
            "Alpha Fund Share", "AFS", address(usdc), address(0), admin, operator, executor, SECONDS_PER_EPOCH
        );
    }

    /// @notice 成功创建基金后应正确登记映射并完成 Vault 初始化参数透传
    function test_createFund_success_registersFundAndVaultInitialization() public {
        vm.prank(owner);
        address vaultAddr = factory.createFund(
            "Alpha Fund Share", "AFS", address(usdc), manager, admin, operator, executor, SECONDS_PER_EPOCH
        );

        assertEq(factory.fundCount(), 1);
        assertEq(factory.fundIds(vaultAddr), 1);

        (
            address fundVault,
            address fundBaseAsset,
            address fundManager,
            address fundAdmin,
            address fundOperator,
            address fundExecutor,
            uint256 fundCreatedAt
        ) = factory.funds(1);
        assertEq(fundVault, vaultAddr);
        assertEq(fundBaseAsset, address(usdc));
        assertEq(fundManager, manager);
        assertEq(fundAdmin, admin);
        assertEq(fundOperator, operator);
        assertEq(fundExecutor, executor);
        assertEq(fundCreatedAt, block.timestamp);

        Vault vault = Vault(vaultAddr);
        assertEq(vault.name(), "Alpha Fund Share");
        assertEq(vault.symbol(), "AFS");
        assertEq(vault.baseAsset(), address(usdc));
        assertEq(vault.admin(), admin);
        assertEq(vault.operator(), operator);
        assertEq(vault.executor(), executor);
        assertEq(vault.secondsPerEpoch(), SECONDS_PER_EPOCH);
    }

    /// @notice 成功创建基金时应触发 FundCreated 事件
    function test_createFund_success_emitsFundCreated() public {
        vm.prank(owner);
        vm.expectEmit(false, true, true, true);
        emit FundCreated(address(0), address(usdc), manager, admin, operator, executor, block.timestamp, 1);

        address vaultAddr = factory.createFund(
            "Alpha Fund Share", "AFS", address(usdc), manager, admin, operator, executor, SECONDS_PER_EPOCH
        );

        assertEq(factory.fundIds(vaultAddr), 1);
    }

    /// @notice 连续创建基金时应分配递增 fundId 且 vault 地址唯一
    function test_createFund_success_assignsIncrementingFundIds() public {
        vm.startPrank(owner);
        address vault1 = factory.createFund(
            "Alpha Fund Share", "AFS", address(usdc), manager, admin, operator, executor, SECONDS_PER_EPOCH
        );
        address vault2 = factory.createFund(
            "Beta Fund Share", "BFS", address(usdc), manager, admin, operator, executor, SECONDS_PER_EPOCH
        );
        vm.stopPrank();

        assertTrue(vault1 != vault2);
        assertEq(factory.fundCount(), 2);
        assertEq(factory.fundIds(vault1), 1);
        assertEq(factory.fundIds(vault2), 2);
    }
}
