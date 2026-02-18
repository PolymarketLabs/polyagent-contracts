// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {VaultTestBase} from "./shared/VaultTestBase.sol";
import {IVaultUser} from "../src/interfaces/IVaultUser.sol";
import {IVaultFee} from "../src/interfaces/IVaultFee.sol";
import {IVaultSettlement} from "../src/interfaces/IVaultSettlement.sol";

contract VaultSettlementTest is VaultTestBase {
    uint256 public constant INITIAL_TIMESTAMP = 1767225600; // 2026-01-01 00:00:00 UTC
    uint256 public constant SECONDS_PER_EPOCH = 86400;
    uint256 public constant INITIAL_MIN_DEPOSIT_AMOUNT = 1;
    uint256 public constant INITIAL_MIN_REDEEM_SHARES = 1;

    event EpochFinalized(uint256 indexed epoch, uint256 totalAum, uint256 sharesAtSettle, uint256 navPerShare);

    function setUp() public {
        _setUpVaultFixture(INITIAL_TIMESTAMP, SECONDS_PER_EPOCH, INITIAL_MIN_DEPOSIT_AMOUNT, INITIAL_MIN_REDEEM_SHARES);
    }

    /// @notice 未封账 epoch 调用 settleDeposits 应回滚
    function test_settleDeposits_reverts_whenEpochNotFinalized() public {
        uint256 epoch = vault.currentEpoch();

        vm.prank(operator);
        vm.expectRevert();
        vault.settleDeposits(epoch, 1);
    }

    /// @notice maxCount 为 0 时 settleDeposits 应回滚
    function test_settleDeposits_reverts_whenMaxCountIsZero() public {
        uint256 epoch = vault.currentEpoch();

        vm.prank(operator);
        vm.expectRevert();
        vault.settleDeposits(epoch, 0);
    }

    /// @notice 申购批结算应按 NAV 铸币、跳过非 Pending 请求并推进游标
    function test_settleDeposits_processesBatchAndUpdatesCursor() public {
        uint256 aliceAmount = 100e6;
        uint256 bobAmount = 50e6;

        vm.prank(address(this));
        assertTrue(usdc.transfer(alice, aliceAmount));
        vm.prank(address(this));
        assertTrue(usdc.transfer(bob, bobAmount));

        vm.startPrank(alice);
        usdc.approve(address(vault), aliceAmount);
        (uint256 epoch, uint256 aliceIndex) = vault.requestDeposit(aliceAmount, address(0));
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(vault), bobAmount);
        (, uint256 bobIndex) = vault.requestDeposit(bobAmount, address(0));
        vault.cancelDeposit(epoch, bobIndex);
        vm.stopPrank();

        uint256 sharesAtSettle = 200e18;
        uint256 totalAum = 500e6;
        deal(address(vault), manager, sharesAtSettle, true);

        vm.prank(admin);
        vault.setFeePolicy(_zeroFeePolicy(), epoch);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));

        vm.prank(operator);
        vault.finalizeEpoch(epoch, totalAum);

        uint256 expectedPricingAum = totalAum - vault.netRequestedDepositAssets(epoch);
        uint256 expectedNavPerShare = (expectedPricingAum * 1e18) / sharesAtSettle;
        uint256 expectedAliceShares = (aliceAmount * 1e18) / expectedNavPerShare;

        vm.prank(operator);
        vault.settleDeposits(epoch, 1);

        (,, IVaultUser.ReqStatus aliceStatus) = vault.depositRequestAt(epoch, aliceIndex);
        (,, IVaultUser.ReqStatus bobStatus) = vault.depositRequestAt(epoch, bobIndex);
        assertEq(uint8(aliceStatus), uint8(IVaultUser.ReqStatus.Settled));
        assertEq(uint8(bobStatus), uint8(IVaultUser.ReqStatus.Canceled));
        assertEq(vault.balanceOf(alice), expectedAliceShares);

        IVaultSettlement.SettlementCursor memory depositCursor = vault.depositCursorOf(epoch);
        IVaultSettlement.SettlementCursor memory redeemCursor = vault.redeemCursorOf(epoch);
        assertEq(depositCursor.nextIndex, 1);
        assertFalse(depositCursor.done);
        assertEq(redeemCursor.nextIndex, 0);
        assertFalse(redeemCursor.done);

        vm.prank(operator);
        vault.settleDeposits(epoch, 10);

        depositCursor = vault.depositCursorOf(epoch);
        redeemCursor = vault.redeemCursorOf(epoch);
        assertEq(depositCursor.nextIndex, 2);
        assertTrue(depositCursor.done);
        assertEq(redeemCursor.nextIndex, 0);
        assertFalse(redeemCursor.done);

        vm.prank(operator);
        vm.expectRevert();
        vault.settleDeposits(epoch, 1);
    }

    /// @notice 未封账 epoch 调用 settleRedeems 应回滚
    function test_settleRedeems_reverts_whenEpochNotFinalized() public {
        uint256 epoch = vault.currentEpoch();

        vm.prank(operator);
        vm.expectRevert();
        vault.settleRedeems(epoch, 1);
    }

    /// @notice maxCount 为 0 时 settleRedeems 应回滚
    function test_settleRedeems_reverts_whenMaxCountIsZero() public {
        uint256 epoch = vault.currentEpoch();

        vm.prank(operator);
        vm.expectRevert();
        vault.settleRedeems(epoch, 0);
    }

    /// @notice 赎回批结算应按 NAV 记入 claimable、跳过非 Pending 请求并推进游标
    function test_settleRedeems_processesBatchAndUpdatesCursor() public {
        uint256 aliceShares = 10e18;
        uint256 bobShares = 5e18;
        uint256 managerShares = 185e18;

        deal(address(vault), alice, aliceShares, true);
        deal(address(vault), bob, bobShares, true);
        deal(address(vault), manager, managerShares, true);

        vm.prank(alice);
        (uint256 epoch, uint256 aliceIndex) = vault.requestRedeem(aliceShares);

        vm.startPrank(bob);
        (, uint256 bobIndex) = vault.requestRedeem(bobShares);
        vault.cancelRedeem(epoch, bobIndex);
        vm.stopPrank();

        uint256 totalAum = 500e6;

        vm.prank(admin);
        vault.setFeePolicy(_zeroFeePolicy(), epoch);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));

        vm.prank(operator);
        vault.finalizeEpoch(epoch, totalAum);

        uint256 expectedNavPerShare = (totalAum * 1e18) / vault.totalSupply();
        uint256 expectedClaimableAssets = (aliceShares * expectedNavPerShare) / 1e18;

        vm.prank(operator);
        vault.settleRedeems(epoch, 1);

        (,, IVaultUser.ReqStatus aliceStatus) = vault.redeemRequestAt(epoch, aliceIndex);
        (,, IVaultUser.ReqStatus bobStatus) = vault.redeemRequestAt(epoch, bobIndex);
        assertEq(uint8(aliceStatus), uint8(IVaultUser.ReqStatus.Settled));
        assertEq(uint8(bobStatus), uint8(IVaultUser.ReqStatus.Canceled));
        assertEq(vault.claimableAssets(alice), expectedClaimableAssets);
        assertEq(vault.balanceOf(address(vault)), 0);

        IVaultSettlement.SettlementCursor memory depositCursor = vault.depositCursorOf(epoch);
        IVaultSettlement.SettlementCursor memory redeemCursor = vault.redeemCursorOf(epoch);
        assertEq(depositCursor.nextIndex, 0);
        assertFalse(depositCursor.done);
        assertEq(redeemCursor.nextIndex, 1);
        assertFalse(redeemCursor.done);

        vm.prank(operator);
        vault.settleRedeems(epoch, 10);

        depositCursor = vault.depositCursorOf(epoch);
        redeemCursor = vault.redeemCursorOf(epoch);
        assertEq(depositCursor.nextIndex, 0);
        assertFalse(depositCursor.done);
        assertEq(redeemCursor.nextIndex, 2);
        assertTrue(redeemCursor.done);

        vm.prank(operator);
        vm.expectRevert();
        vault.settleRedeems(epoch, 1);
    }

    /// @notice 当前或未来 epoch 封账应回滚
    function test_finalizeEpoch_reverts_forCurrentOrFutureEpoch() public {
        uint256 current = vault.currentEpoch();

        vm.prank(operator);
        vm.expectRevert();
        vault.finalizeEpoch(current, 100e6);

        vm.prank(operator);
        vm.expectRevert();
        vault.finalizeEpoch(current + 1, 100e6);
    }

    /// @notice 同一 epoch 二次封账应回滚
    function test_finalizeEpoch_reverts_whenCalledTwiceForSameEpoch() public {
        uint256 epoch = vault.currentEpoch() + 1;
        vm.prank(admin);
        vault.setFeePolicy(_zeroFeePolicy(), epoch);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));
        vm.prank(operator);
        vault.finalizeEpoch(epoch, 100e6);

        vm.prank(operator);
        vm.expectRevert();
        vault.finalizeEpoch(epoch, 200e6);
    }

    /// @notice 封账应写入快照并触发事件
    function test_finalizeEpoch_storesSnapshotAndEmitsEvent() public {
        uint256 sharesAtSettle = 200e18;
        uint256 totalAum = 500e6;
        uint256 epoch = vault.currentEpoch() + 1;
        vm.prank(admin);
        vault.setFeePolicy(_zeroFeePolicy(), epoch);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));
        uint256 expectedNavPerShare = (totalAum * 1e18) / sharesAtSettle;

        deal(address(vault), alice, sharesAtSettle, true);

        vm.prank(operator);
        vm.expectEmit(true, true, true, true);
        emit EpochFinalized(epoch, totalAum, sharesAtSettle, expectedNavPerShare);
        vault.finalizeEpoch(epoch, totalAum);

        IVaultSettlement.EpochSnapshot memory snapshot = vault.snapshotOf(epoch);
        assertEq(snapshot.totalAum, totalAum);
        assertEq(snapshot.sharesAtSettle, sharesAtSettle);
        assertEq(snapshot.navPerShare, expectedNavPerShare);
        assertEq(snapshot.finalizedAt, block.timestamp);
    }

    /// @notice totalAum 小于当期净申购额时 finalizeEpoch 应回滚
    function test_finalizeEpoch_reverts_whenTotalAumLessThanNetRequestedDeposits() public {
        uint256 depositAmount = 100e6;
        vm.prank(address(this));
        assertTrue(usdc.transfer(alice, depositAmount));

        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        (uint256 epoch,) = vault.requestDeposit(depositAmount, address(0));
        vm.stopPrank();

        vm.prank(admin);
        vault.setFeePolicy(_zeroFeePolicy(), epoch);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));

        vm.prank(operator);
        vm.expectRevert();
        vault.finalizeEpoch(epoch, depositAmount - 1);
    }

    /// @notice 当 epoch 无申购请求时，settleDeposits 应直接将游标置为 done
    function test_settleDeposits_marksDone_whenNoDepositRequests() public {
        uint256 epoch = vault.currentEpoch();
        vm.prank(admin);
        vault.setFeePolicy(_zeroFeePolicy(), epoch);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));
        vm.prank(operator);
        vault.finalizeEpoch(epoch, 100e6);

        vm.prank(operator);
        vault.settleDeposits(epoch, 10);

        IVaultSettlement.SettlementCursor memory cursor = vault.depositCursorOf(epoch);
        assertEq(cursor.nextIndex, 0);
        assertTrue(cursor.done);
    }

    /// @notice 当 epoch 无赎回请求时，settleRedeems 应直接将游标置为 done
    function test_settleRedeems_marksDone_whenNoRedeemRequests() public {
        uint256 epoch = vault.currentEpoch();
        vm.prank(admin);
        vault.setFeePolicy(_zeroFeePolicy(), epoch);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));
        vm.prank(operator);
        vault.finalizeEpoch(epoch, 100e6);

        vm.prank(operator);
        vault.settleRedeems(epoch, 10);

        IVaultSettlement.SettlementCursor memory cursor = vault.redeemCursorOf(epoch);
        assertEq(cursor.nextIndex, 0);
        assertTrue(cursor.done);
    }

    /// @notice navPerShare 为 0 时，settleDeposits 应回滚
    function test_settleDeposits_reverts_whenNavPerShareIsZero() public {
        uint256 depositAmount = 100e6;
        uint256 managerShares = 100e18;
        deal(address(vault), manager, managerShares, true);

        vm.prank(address(this));
        assertTrue(usdc.transfer(alice, depositAmount));
        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        (uint256 epoch,) = vault.requestDeposit(depositAmount, address(0));
        vm.stopPrank();

        vm.prank(admin);
        vault.setFeePolicy(_zeroFeePolicy(), epoch);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));
        // totalAum == 净申购，定价 AUM 为 0，且 sharesAtSettle > 0，因此 navPerShare = 0
        vm.prank(operator);
        vault.finalizeEpoch(epoch, depositAmount);

        vm.prank(operator);
        vm.expectRevert();
        vault.settleDeposits(epoch, 10);
    }

    /// @notice navPerShare 为 0 时，settleRedeems 应回滚
    function test_settleRedeems_reverts_whenNavPerShareIsZero() public {
        uint256 managerShares = 100e18;
        uint256 redeemShares = 10e18;
        deal(address(vault), manager, managerShares, true);
        deal(address(vault), alice, redeemShares, true);

        vm.prank(alice);
        (uint256 epoch,) = vault.requestRedeem(redeemShares);

        vm.prank(admin);
        vault.setFeePolicy(_zeroFeePolicy(), epoch);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));
        // sharesAtSettle > 0 且 totalAum 为 0，因此 navPerShare = 0
        vm.prank(operator);
        vault.finalizeEpoch(epoch, 0);

        vm.prank(operator);
        vm.expectRevert();
        vault.settleRedeems(epoch, 10);
    }

    /// @notice finalizeEpoch 传入早于 epoch0 的 epoch 时应回滚
    function test_finalizeEpoch_reverts_whenEpochBeforeEpoch0() public {
        uint256 invalidEpoch = vault.epoch0() - 1;
        vm.prank(operator);
        vm.expectRevert();
        vault.finalizeEpoch(invalidEpoch, 100e6);
    }

    function _zeroFeePolicy() internal view returns (IVaultFee.FeePolicy memory policy) {
        policy = IVaultFee.FeePolicy({
            rates: IVaultFee.FeeRateConfig({entryFeeBps: 0, exitFeeBps: 0, mgmtFeeAnnualBps: 0, performanceFeeBps: 0}),
            entrySplit: IVaultFee.SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 0}),
            exitSplit: IVaultFee.SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 0}),
            mgmtSplit: IVaultFee.SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 0}),
            performanceSplit: IVaultFee.SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 0}),
            recipients: IVaultFee.FeeRecipientConfig({platform: admin, manager: manager, reserve: executor})
        });
    }
}
