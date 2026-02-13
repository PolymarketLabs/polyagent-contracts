// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../src/Vault.sol";
import {VaultAdmin} from "../src/VaultAdmin.sol";
import {USDC} from "./mocks/USDC.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {VaultFactory} from "../src/VaultFactory.sol";

contract VaultAdminTest is Test {
    uint256 public constant INITIAL_TIMESTAMP = 1767225600; // 2026-01-01 00:00:00 UTC
    uint256 public constant SECONDS_PER_EPOCH = 86400;

    USDC public usdc;
    VaultFactory public factory;
    Vault public vault;

    address beaconOwner = makeAddr("beaconOwner");
    address owner = makeAddr("owner");
    address manager = makeAddr("manager");
    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address executor = makeAddr("executor");
    address alice = makeAddr("alice");
    address carol = makeAddr("carol");

    event AdminUpdated(address indexed previousAdmin, address indexed newAdmin);
    event OperatorUpdated(address indexed previousOperator, address indexed newOperator);
    event ExecutorUpdated(address indexed previousExecutor, address indexed newExecutor);
    event DepositPauseStatusUpdated(address indexed admin, bool paused);
    event RedeemPauseStatusUpdated(address indexed admin, bool paused);

    function setUp() public {
        vm.warp(INITIAL_TIMESTAMP);
        usdc = new USDC();

        factory = _deployFactory(owner);
        vault = Vault(_createFund(factory, address(usdc), manager, admin, operator, executor, SECONDS_PER_EPOCH));
    }

    /// @notice setAdmin 应仅允许 admin 调用，并同步迁移 DEFAULT_ADMIN_ROLE
    function test_setAdmin_onlyAdminCanSetAndMigratesRole() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setAdmin(carol);

        vm.expectEmit(true, true, false, true);
        emit AdminUpdated(admin, carol);
        vm.prank(admin);
        vault.setAdmin(carol);

        assertEq(vault.admin(), carol);
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), carol));
        assertFalse(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));

        vm.prank(admin);
        vm.expectRevert();
        vault.pauseDeposit();

        vm.prank(carol);
        vault.pauseDeposit();
        assertTrue(vault.depositPaused());
    }

    /// @notice setOperator 应仅允许 admin 调用，并同步迁移 OPERATOR_ROLE
    function test_setOperator_onlyAdminCanSetAndMigratesRole() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setOperator(carol);

        vm.expectEmit(true, true, false, true);
        emit OperatorUpdated(operator, carol);
        vm.prank(admin);
        vault.setOperator(carol);

        assertEq(vault.operator(), carol);
        assertTrue(vault.hasRole(vault.OPERATOR_ROLE(), carol));
        assertFalse(vault.hasRole(vault.OPERATOR_ROLE(), operator));

        vm.prank(address(this));
        assertTrue(usdc.transfer(address(vault), 10e6));

        vm.prank(operator);
        vm.expectRevert();
        vault.transferToExecutor(1e6);

        vm.prank(carol);
        vault.transferToExecutor(1e6);
        assertEq(usdc.balanceOf(executor), 1e6);
    }

    /// @notice setExecutor 应仅允许 admin 调用，并影响后续 transferToExecutor 的收款地址
    function test_setExecutor_onlyAdminCanSetAndAffectsTransferTarget() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setExecutor(carol);

        vm.expectEmit(true, true, false, true);
        emit ExecutorUpdated(executor, carol);
        vm.prank(admin);
        vault.setExecutor(carol);

        assertEq(vault.executor(), carol);

        uint256 amount = 7e6;
        vm.prank(address(this));
        assertTrue(usdc.transfer(address(vault), amount));

        vm.prank(operator);
        vault.transferToExecutor(amount);

        assertEq(usdc.balanceOf(carol), amount);
        assertEq(usdc.balanceOf(executor), 0);
    }

    /// @notice setAdmin/setOperator/setExecutor 的新地址为零地址时应回滚
    function test_setRoleAddresses_reverts_whenZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(VaultAdmin.ZeroAddress.selector);
        vault.setAdmin(address(0));

        vm.prank(admin);
        vm.expectRevert(VaultAdmin.ZeroAddress.selector);
        vault.setOperator(address(0));

        vm.prank(admin);
        vm.expectRevert(VaultAdmin.ZeroAddress.selector);
        vault.setExecutor(address(0));
    }

    /// @notice 仅 admin 可切换申购暂停状态，重复切换应回滚
    function test_pauseDeposit_onlyAdminCanToggle() public {
        assertFalse(vault.depositPaused());

        vm.prank(alice);
        vm.expectRevert();
        vault.pauseDeposit();

        vm.expectEmit(true, false, false, true);
        emit DepositPauseStatusUpdated(admin, true);
        vm.prank(admin);
        vault.pauseDeposit();
        assertTrue(vault.depositPaused());

        vm.prank(admin);
        vm.expectRevert(VaultAdmin.DepositPaused.selector);
        vault.pauseDeposit();

        vm.prank(alice);
        vm.expectRevert();
        vault.unpauseDeposit();

        vm.expectEmit(true, false, false, true);
        emit DepositPauseStatusUpdated(admin, false);
        vm.prank(admin);
        vault.unpauseDeposit();
        assertFalse(vault.depositPaused());

        vm.prank(admin);
        vm.expectRevert(VaultAdmin.DepositNotPaused.selector);
        vault.unpauseDeposit();
    }

    /// @notice 仅 admin 可切换赎回暂停状态，重复切换应回滚
    function test_pauseRedeem_onlyAdminCanToggle() public {
        assertFalse(vault.redeemPaused());

        vm.prank(alice);
        vm.expectRevert();
        vault.pauseRedeem();

        vm.expectEmit(true, false, false, true);
        emit RedeemPauseStatusUpdated(admin, true);
        vm.prank(admin);
        vault.pauseRedeem();
        assertTrue(vault.redeemPaused());

        vm.prank(admin);
        vm.expectRevert(VaultAdmin.RedeemPaused.selector);
        vault.pauseRedeem();

        vm.prank(alice);
        vm.expectRevert();
        vault.unpauseRedeem();

        vm.expectEmit(true, false, false, true);
        emit RedeemPauseStatusUpdated(admin, false);
        vm.prank(admin);
        vault.unpauseRedeem();
        assertFalse(vault.redeemPaused());

        vm.prank(admin);
        vm.expectRevert(VaultAdmin.RedeemNotPaused.selector);
        vault.unpauseRedeem();
    }

    function _deployFactory(address initialOwner) internal returns (VaultFactory localFactory) {
        Vault implementation = new Vault();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(implementation), beaconOwner);
        VaultFactory factoryImplementation = new VaultFactory();
        bytes memory initData = abi.encodeCall(VaultFactory.initialize, (address(beacon), initialOwner));
        localFactory = VaultFactory(address(new ERC1967Proxy(address(factoryImplementation), initData)));
    }

    function _createFund(
        VaultFactory targetFactory,
        address baseAsset,
        address _manager,
        address _admin,
        address _operator,
        address _executor,
        uint256 _secondsPerEpoch
    ) internal returns (address vaultProxy) {
        vm.prank(owner);
        vaultProxy = targetFactory.createFund(
            "Alpha Fund Share", "AFS", baseAsset, _manager, _admin, _operator, _executor, _secondsPerEpoch
        );
    }
}
