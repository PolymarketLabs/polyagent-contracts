// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {VaultTestBase} from "./shared/VaultTestBase.sol";

contract VaultPausableTest is VaultTestBase {
    uint256 public constant INITIAL_TIMESTAMP = 1767225600; // 2026-01-01 00:00:00 UTC
    uint256 public constant SECONDS_PER_EPOCH = 86400;
    uint256 public constant INITIAL_MIN_DEPOSIT_AMOUNT = 1;
    uint256 public constant INITIAL_MIN_REDEEM_SHARES = 1;

    event DepositPauseStatusUpdated(address indexed admin, bool paused);
    event RedeemPauseStatusUpdated(address indexed admin, bool paused);

    function setUp() public {
        _setUpVaultFixture(INITIAL_TIMESTAMP, SECONDS_PER_EPOCH, INITIAL_MIN_DEPOSIT_AMOUNT, INITIAL_MIN_REDEEM_SHARES);
    }

    /// @notice 申购暂停期间，requestDeposit 应回滚
    function test_requestDeposit_reverts_whenDepositPaused() public {
        uint256 amount = 100e6;
        vm.prank(address(this));
        assertTrue(usdc.transfer(alice, amount));

        vm.prank(admin);
        vault.pauseDeposit();

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vm.expectRevert();
        vault.requestDeposit(amount, address(0));
        vm.stopPrank();
    }

    /// @notice 赎回暂停期间，requestRedeem 应回滚
    function test_requestRedeem_reverts_whenRedeemPaused() public {
        uint256 shares = 10e18;
        deal(address(vault), alice, shares, true);

        vm.prank(admin);
        vault.pauseRedeem();

        vm.prank(alice);
        vm.expectRevert();
        vault.requestRedeem(shares);
    }

    /// @notice pauseDeposit / unpauseDeposit 应更新状态并触发事件
    function test_pauseAndUnpauseDeposit_updatesStateAndEmitsEvent() public {
        assertFalse(vault.depositPaused());

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit DepositPauseStatusUpdated(admin, true);
        vault.pauseDeposit();
        assertTrue(vault.depositPaused());

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit DepositPauseStatusUpdated(admin, false);
        vault.unpauseDeposit();
        assertFalse(vault.depositPaused());
    }

    /// @notice 已暂停时再次 pauseDeposit 应回滚
    function test_pauseDeposit_reverts_whenAlreadyPaused() public {
        vm.prank(admin);
        vault.pauseDeposit();

        vm.prank(admin);
        vm.expectRevert();
        vault.pauseDeposit();
    }

    /// @notice 未暂停时直接 unpauseDeposit 应回滚
    function test_unpauseDeposit_reverts_whenNotPaused() public {
        vm.prank(admin);
        vm.expectRevert();
        vault.unpauseDeposit();
    }

    /// @notice pauseRedeem / unpauseRedeem 应更新状态并触发事件
    function test_pauseAndUnpauseRedeem_updatesStateAndEmitsEvent() public {
        assertFalse(vault.redeemPaused());

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit RedeemPauseStatusUpdated(admin, true);
        vault.pauseRedeem();
        assertTrue(vault.redeemPaused());

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit RedeemPauseStatusUpdated(admin, false);
        vault.unpauseRedeem();
        assertFalse(vault.redeemPaused());
    }

    /// @notice 已暂停时再次 pauseRedeem 应回滚
    function test_pauseRedeem_reverts_whenAlreadyPaused() public {
        vm.prank(admin);
        vault.pauseRedeem();

        vm.prank(admin);
        vm.expectRevert();
        vault.pauseRedeem();
    }

    /// @notice 未暂停时直接 unpauseRedeem 应回滚
    function test_unpauseRedeem_reverts_whenNotPaused() public {
        vm.prank(admin);
        vm.expectRevert();
        vault.unpauseRedeem();
    }
}
