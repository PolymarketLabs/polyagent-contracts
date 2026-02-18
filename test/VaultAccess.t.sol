// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {VaultTestBase} from "./shared/VaultTestBase.sol";
import {VaultFactory} from "../src/VaultFactory.sol";

contract VaultAccessTest is VaultTestBase {
    uint256 public constant INITIAL_TIMESTAMP = 1767225600; // 2026-01-01 00:00:00 UTC
    uint256 public constant SECONDS_PER_EPOCH = 86400;
    uint256 public constant INITIAL_MIN_DEPOSIT_AMOUNT = 1;
    uint256 public constant INITIAL_MIN_REDEEM_SHARES = 1;

    event AdminUpdated(address indexed previousAdmin, address indexed newAdmin);
    event OperatorUpdated(address indexed previousOperator, address indexed newOperator);
    event ExecutorUpdated(address indexed previousExecutor, address indexed newExecutor);

    function setUp() public {
        _setUpVaultFixture(INITIAL_TIMESTAMP, SECONDS_PER_EPOCH, INITIAL_MIN_DEPOSIT_AMOUNT, INITIAL_MIN_REDEEM_SHARES);
    }

    /// @notice 验证 admin/operator/executor 地址及角色绑定正确
    function test_initialize_setsRoleBindings() public view {
        assertEq(vault.admin(), admin);
        assertEq(vault.operator(), operator);
        assertEq(vault.executor(), executor);
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.OPERATOR_ROLE(), operator));
    }

    /// @notice admin 为零地址时应回滚
    function test_initialize_reverts_whenAdminIsZero() public {
        VaultFactory localFactory = _deployFactory(owner);
        vm.prank(owner);
        vm.expectRevert();
        localFactory.createFund(
            "Alpha Fund Share",
            "AFS",
            address(usdc),
            manager,
            address(0),
            operator,
            executor,
            SECONDS_PER_EPOCH,
            INITIAL_MIN_DEPOSIT_AMOUNT,
            INITIAL_MIN_REDEEM_SHARES
        );
    }

    /// @notice operator 为零地址时应回滚
    function test_initialize_reverts_whenOperatorIsZero() public {
        VaultFactory localFactory = _deployFactory(owner);
        vm.prank(owner);
        vm.expectRevert();
        localFactory.createFund(
            "Alpha Fund Share",
            "AFS",
            address(usdc),
            manager,
            admin,
            address(0),
            executor,
            SECONDS_PER_EPOCH,
            INITIAL_MIN_DEPOSIT_AMOUNT,
            INITIAL_MIN_REDEEM_SHARES
        );
    }

    /// @notice executor 为零地址时应回滚
    function test_initialize_reverts_whenExecutorIsZero() public {
        VaultFactory localFactory = _deployFactory(owner);
        vm.prank(owner);
        vm.expectRevert();
        localFactory.createFund(
            "Alpha Fund Share",
            "AFS",
            address(usdc),
            manager,
            admin,
            operator,
            address(0),
            SECONDS_PER_EPOCH,
            INITIAL_MIN_DEPOSIT_AMOUNT,
            INITIAL_MIN_REDEEM_SHARES
        );
    }

    /// @notice 非 operator 调用 finalizeEpoch 应回滚
    function test_finalizeEpoch_reverts_whenCalledByNonOperator() public {
        uint256 epoch = vault.currentEpoch() - 1;
        vm.prank(alice);
        vm.expectRevert();
        vault.finalizeEpoch(epoch, 100e6);
    }

    /// @notice admin 可更新 admin 地址，角色应随之迁移并触发事件
    function test_setAdmin_updatesRoleBindingAndEmitsEvent() public {
        address newAdmin = carol;

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit AdminUpdated(admin, newAdmin);
        vault.setAdmin(newAdmin);

        assertEq(vault.admin(), newAdmin);
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), newAdmin));
        assertFalse(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
    }

    /// @notice admin 可更新 operator 地址，角色应随之迁移并触发事件
    function test_setOperator_updatesRoleBindingAndEmitsEvent() public {
        address newOperator = carol;

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit OperatorUpdated(operator, newOperator);
        vault.setOperator(newOperator);

        assertEq(vault.operator(), newOperator);
        assertTrue(vault.hasRole(vault.OPERATOR_ROLE(), newOperator));
        assertFalse(vault.hasRole(vault.OPERATOR_ROLE(), operator));
    }

    /// @notice admin 可更新 executor 地址，并触发事件
    function test_setExecutor_updatesExecutorAndEmitsEvent() public {
        address newExecutor = carol;

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit ExecutorUpdated(executor, newExecutor);
        vault.setExecutor(newExecutor);

        assertEq(vault.executor(), newExecutor);
    }

    /// @notice setAdmin/setOperator/setExecutor 传入当前值应 no-op，不发事件
    function test_setAccessRole_noOpWhenSettingSameAddress() public {
        vm.recordLogs();
        vm.startPrank(admin);
        vault.setAdmin(admin);
        vault.setOperator(operator);
        vault.setExecutor(executor);
        vm.stopPrank();

        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(vault.admin(), admin);
        assertEq(vault.operator(), operator);
        assertEq(vault.executor(), executor);
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.OPERATOR_ROLE(), operator));
    }
}
