// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {VaultTestBase} from "./shared/VaultTestBase.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract VaultTest is VaultTestBase {
    uint256 public constant INITIAL_TIMESTAMP = 1767225600; // 2026-01-01 00:00:00 UTC
    uint256 public constant SECONDS_PER_EPOCH = 86400;
    uint256 public constant INITIAL_MIN_DEPOSIT_AMOUNT = 1;
    uint256 public constant INITIAL_MIN_REDEEM_SHARES = 1;

    event BaseAssetTransferredToExecutor(address indexed operator, address indexed executor, uint256 amount);

    function setUp() public {
        _setUpVaultFixture(INITIAL_TIMESTAMP, SECONDS_PER_EPOCH, INITIAL_MIN_DEPOSIT_AMOUNT, INITIAL_MIN_REDEEM_SHARES);
    }

    /// @notice baseAsset 为零地址时应回滚
    function test_initialize_reverts_whenBaseAssetIsZero() public {
        VaultFactory localFactory = _deployFactory(owner);
        vm.prank(owner);
        vm.expectRevert();
        localFactory.createFund(
            "Alpha Fund Share",
            "AFS",
            address(0),
            manager,
            admin,
            operator,
            executor,
            SECONDS_PER_EPOCH,
            INITIAL_MIN_DEPOSIT_AMOUNT,
            INITIAL_MIN_REDEEM_SHARES
        );
    }

    /// @notice 代理初始化后再次调用 initialize 应回滚
    function test_initialize_cannotBeCalledTwice() public {
        vm.expectRevert();
        vault.initialize(
            "Another Share",
            "ASH",
            address(usdc),
            admin,
            operator,
            executor,
            SECONDS_PER_EPOCH,
            INITIAL_MIN_DEPOSIT_AMOUNT,
            INITIAL_MIN_REDEEM_SHARES
        );
    }

    /// @notice operator 调用应将 baseAsset 转到 executor，并触发事件
    function test_transferBaseAssetToExecutor_transfersAssetsAndEmitsEvent() public {
        uint256 amount = 100e6;
        assertTrue(usdc.transfer(address(vault), amount));

        vm.prank(operator);
        vm.expectEmit(true, true, true, true);
        emit BaseAssetTransferredToExecutor(operator, executor, amount);
        vault.transferBaseAssetToExecutor(amount);

        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(executor), amount);
    }

    /// @notice 非 operator 调用应回滚
    function test_transferBaseAssetToExecutor_reverts_whenCallerIsNotOperator() public {
        vm.prank(outsider);
        vm.expectRevert();
        vault.transferBaseAssetToExecutor(1);
    }

    /// @notice 更新 executor 后，转账目标应变为新 executor
    function test_transferBaseAssetToExecutor_transfersToUpdatedExecutor() public {
        uint256 amount = 100e6;
        assertTrue(usdc.transfer(address(vault), amount));

        vm.prank(admin);
        vault.setExecutor(carol);

        vm.prank(operator);
        vault.transferBaseAssetToExecutor(amount);

        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(executor), 0);
        assertEq(usdc.balanceOf(carol), amount);
    }

    /// @notice Vault baseAsset 余额不足时应回滚
    function test_transferBaseAssetToExecutor_reverts_whenVaultBalanceInsufficient() public {
        uint256 amount = 100e6;

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(vault), 0, amount)
        );
        vault.transferBaseAssetToExecutor(amount);
    }

    /// @notice amount 为 0 时允许调用，余额不变并触发事件
    function test_transferBaseAssetToExecutor_allowsZeroAmount() public {
        uint256 initialVaultBalance = usdc.balanceOf(address(vault));
        uint256 initialExecutorBalance = usdc.balanceOf(executor);

        vm.prank(operator);
        vm.expectEmit(true, true, true, true);
        emit BaseAssetTransferredToExecutor(operator, executor, 0);
        vault.transferBaseAssetToExecutor(0);

        assertEq(usdc.balanceOf(address(vault)), initialVaultBalance);
        assertEq(usdc.balanceOf(executor), initialExecutorBalance);
    }
}
