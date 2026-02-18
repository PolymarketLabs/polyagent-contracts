// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {VaultTestBase} from "./shared/VaultTestBase.sol";
import {IVaultFee} from "../src/interfaces/IVaultFee.sol";
import {IVaultSettlement} from "../src/interfaces/IVaultSettlement.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract VaultFeeTest is VaultTestBase {
    using stdStorage for StdStorage;

    uint256 public constant INITIAL_TIMESTAMP = 1767225600; // 2026-01-01 00:00:00 UTC
    uint256 public constant SECONDS_PER_EPOCH = 86400;
    uint256 public constant INITIAL_MIN_DEPOSIT_AMOUNT = 1;
    uint256 public constant INITIAL_MIN_REDEEM_SHARES = 1;

    event FeeClaimed(address indexed recipient, address indexed to, uint256 amount);

    function setUp() public {
        _setUpVaultFixture(INITIAL_TIMESTAMP, SECONDS_PER_EPOCH, INITIAL_MIN_DEPOSIT_AMOUNT, INITIAL_MIN_REDEEM_SHARES);
    }

    /// @notice settleDeposits 应按 ENTRY 费率扣费，并把推荐人分账记入 feeClaimable
    function test_settleDeposits_appliesEntryFeeAndAccruesFeeClaimable_withReferrer() public {
        uint256 managerShares = 200e18;
        uint256 depositAmount = 100e6;
        uint256 totalAum = 500e6;
        deal(address(vault), manager, managerShares, true);

        vm.prank(address(this));
        assertTrue(usdc.transfer(alice, depositAmount));
        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        (uint256 epoch,) = vault.requestDeposit(depositAmount, bob);
        vm.stopPrank();

        vm.prank(admin);
        vault.setFeePolicy(_entryFeePolicy(), epoch);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));
        vm.prank(operator);
        vault.finalizeEpoch(epoch, totalAum);

        uint256 pricingAum = totalAum - vault.netRequestedDepositAssets(epoch);
        uint256 navPerShare = (pricingAum * 1e18) / managerShares;
        uint256 entryFee = (depositAmount * 1000) / 10_000;
        uint256 netAmount = depositAmount - entryFee;
        uint256 expectedShares = (netAmount * 1e18) / navPerShare;

        vm.prank(operator);
        vault.settleDeposits(epoch, 10);

        assertEq(vault.balanceOf(alice), expectedShares);
        assertEq(vault.feeClaimable(admin), (entryFee * 3000) / 10_000);
        assertEq(vault.feeClaimable(bob), (entryFee * 2000) / 10_000);
        assertEq(vault.feeClaimable(manager), (entryFee * 5000) / 10_000);
        assertEq(vault.feeClaimable(executor), 0);
    }

    /// @notice 无推荐人时，推荐人分账应回流到 reserve
    function test_settleDeposits_appliesEntryFeeAndRoutesReferrerShareToReserve_whenNoReferrer() public {
        uint256 managerShares = 200e18;
        uint256 depositAmount = 100e6;
        uint256 totalAum = 500e6;
        deal(address(vault), manager, managerShares, true);

        vm.prank(address(this));
        assertTrue(usdc.transfer(alice, depositAmount));
        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        (uint256 epoch,) = vault.requestDeposit(depositAmount, address(0));
        vm.stopPrank();

        vm.prank(admin);
        vault.setFeePolicy(_entryFeePolicy(), epoch);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));
        vm.prank(operator);
        vault.finalizeEpoch(epoch, totalAum);

        uint256 entryFee = (depositAmount * 1000) / 10_000;
        vm.prank(operator);
        vault.settleDeposits(epoch, 10);

        assertEq(vault.feeClaimable(admin), (entryFee * 3000) / 10_000);
        assertEq(vault.feeClaimable(manager), (entryFee * 5000) / 10_000);
        assertEq(vault.feeClaimable(executor), (entryFee * 2000) / 10_000);
        assertEq(vault.feeClaimable(bob), 0);
    }

    /// @notice settleRedeems 应按 EXIT 费率扣费，并把推荐人分账记入 feeClaimable
    function test_settleRedeems_appliesExitFeeAndAccruesFeeClaimable_withReferrer() public {
        uint256 aliceShares = 10e18;
        uint256 managerShares = 190e18;
        uint256 totalAum = 500e6;
        deal(address(vault), alice, aliceShares, true);
        deal(address(vault), manager, managerShares, true);

        vm.prank(alice);
        vault.bindReferrer(bob);

        vm.prank(alice);
        (uint256 epoch,) = vault.requestRedeem(aliceShares);

        vm.prank(admin);
        vault.setFeePolicy(_exitFeePolicy(), epoch);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));
        vm.prank(operator);
        vault.finalizeEpoch(epoch, totalAum);

        uint256 navPerShare = (totalAum * 1e18) / (aliceShares + managerShares);
        uint256 grossAssets = (aliceShares * navPerShare) / 1e18;
        uint256 exitFee = (grossAssets * 1000) / 10_000;
        uint256 netAssets = grossAssets - exitFee;

        vm.prank(operator);
        vault.settleRedeems(epoch, 10);

        assertEq(vault.claimableAssets(alice), netAssets);
        assertEq(vault.feeClaimable(admin), (exitFee * 3000) / 10_000);
        assertEq(vault.feeClaimable(bob), (exitFee * 2000) / 10_000);
        assertEq(vault.feeClaimable(manager), (exitFee * 5000) / 10_000);
        assertEq(vault.feeClaimable(executor), 0);
    }

    /// @notice finalizeEpoch 应按年化管理费率按期计提，并将费用分账记入 feeClaimable
    function test_finalizeEpoch_appliesManagementFeeAndAccruesFeeClaimable() public {
        uint256 managerShares = 100e18;
        uint256 totalAum = 1_000_000e6;
        deal(address(vault), manager, managerShares, true);

        uint256 epoch = vault.currentEpoch() + 1;
        vm.prank(admin);
        vault.setFeePolicy(_mgmtFeePolicy(), epoch);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));

        vm.prank(operator);
        vault.finalizeEpoch(epoch, totalAum);

        uint256 mgmtFee = (totalAum * 365 * SECONDS_PER_EPOCH) / (10_000 * 365 days);
        uint256 expectedPricingAum = totalAum - mgmtFee;
        uint256 expectedNav = (expectedPricingAum * 1e18) / managerShares;

        IVaultSettlement.EpochSnapshot memory snapshot = vault.snapshotOf(epoch);
        assertEq(snapshot.totalAum, expectedPricingAum);
        assertEq(snapshot.navPerShare, expectedNav);
        assertEq(vault.highWaterMarkNav(), expectedNav);
        assertEq(vault.feeClaimable(admin), (mgmtFee * 3000) / 10_000);
        assertEq(vault.feeClaimable(manager), (mgmtFee * 7000) / 10_000);
        assertEq(vault.feeClaimable(executor), 0);
    }

    /// @notice 若跨多个 epoch 才再次封账，管理费应按与上次封账间隔秒数计提
    function test_finalizeEpoch_appliesManagementFeeByGapFromLastFinalizedEpoch() public {
        uint256 managerShares = 100e18;
        uint256 totalAum = 1_000_000e6;
        deal(address(vault), manager, managerShares, true);

        uint256 epoch1 = vault.currentEpoch();
        vm.prank(admin);
        vault.setFeePolicy(_mgmtFeePolicy(), epoch1);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));
        vm.prank(operator);
        vault.finalizeEpoch(epoch1, totalAum);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));
        uint256 epoch3 = epoch1 + 2;
        vm.prank(operator);
        vault.finalizeEpoch(epoch3, totalAum);

        uint256 firstMgmtFee = 0;
        uint256 secondMgmtFee = (totalAum * 365 * (2 * SECONDS_PER_EPOCH)) / (10_000 * 365 days);

        IVaultSettlement.EpochSnapshot memory snapshot3 = vault.snapshotOf(epoch3);
        assertEq(snapshot3.totalAum, totalAum - secondMgmtFee);
        assertEq(snapshot3.navPerShare, ((totalAum - secondMgmtFee) * 1e18) / managerShares);
        assertEq(vault.lastFinalizedEpoch(), epoch3);

        uint256 totalMgmtFee = firstMgmtFee + secondMgmtFee;
        assertEq(vault.feeClaimable(admin), (totalMgmtFee * 3000) / 10_000);
        assertEq(vault.feeClaimable(manager), (totalMgmtFee * 7000) / 10_000);
        assertEq(vault.feeClaimable(executor), 0);
    }

    /// @notice 业绩报酬仅在 NAV 超过高水位时收取，并在封账后更新高水位
    function test_finalizeEpoch_appliesPerformanceFeeAboveHighWaterMark() public {
        uint256 managerShares = 100e18;
        deal(address(vault), manager, managerShares, true);

        uint256 epoch1 = vault.currentEpoch();
        vm.prank(admin);
        vault.setFeePolicy(_performanceFeePolicy(), epoch1);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));
        vm.prank(operator);
        vault.finalizeEpoch(epoch1, 500e6);

        assertEq(vault.feeClaimable(manager), 0);
        IVaultSettlement.EpochSnapshot memory snapshot1 = vault.snapshotOf(epoch1);
        assertEq(vault.highWaterMarkNav(), snapshot1.navPerShare);

        vm.warp(block.timestamp + SECONDS_PER_EPOCH);
        uint256 epoch2 = epoch1 + 1;

        vm.prank(operator);
        vault.finalizeEpoch(epoch2, 700e6);

        uint256 performanceFee = (200e6 * 2000) / 10_000;
        uint256 expectedPricingAumEpoch2 = 700e6 - performanceFee;
        uint256 expectedNavEpoch2 = (expectedPricingAumEpoch2 * 1e18) / managerShares;

        IVaultSettlement.EpochSnapshot memory snapshot2 = vault.snapshotOf(epoch2);
        assertEq(snapshot2.totalAum, expectedPricingAumEpoch2);
        assertEq(snapshot2.navPerShare, expectedNavEpoch2);
        assertEq(vault.highWaterMarkNav(), expectedNavEpoch2);
        assertEq(vault.feeClaimable(manager), performanceFee);
        assertEq(vault.feeClaimable(admin), 0);
        assertEq(vault.feeClaimable(executor), 0);
    }

    /// @notice claimFee 应转出可领取费用并触发 FeeClaimed
    function test_claimFee_transfersFeeAndEmitsEvent() public {
        uint256 amount = 100e6;
        vm.prank(address(this));
        assertTrue(usdc.transfer(address(vault), amount));
        _setFeeClaimable(alice, amount);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit FeeClaimed(alice, bob, amount);
        uint256 claimedAmount = vault.claimFee(bob);

        assertEq(claimedAmount, amount);
        assertEq(vault.feeClaimable(alice), 0);
        assertEq(usdc.balanceOf(bob), amount);
    }

    /// @notice claimFee 在无可领取费用时应回滚
    function test_claimFee_reverts_whenNoClaimableFee() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.claimFee(bob);
    }

    /// @notice claimFee 的收款地址为零地址时应回滚
    function test_claimFee_reverts_whenToIsZeroAddress() public {
        _setFeeClaimable(alice, 1);

        vm.prank(alice);
        vm.expectRevert();
        vault.claimFee(address(0));
    }

    /// @notice 当 Vault 持有的 baseAsset 不足以覆盖可领取费用时，claimFee 应回滚
    function test_claimFee_reverts_whenVaultBaseAssetInsufficient() public {
        uint256 claimableAmount = 100e6;
        uint256 vaultBalance = 50e6;
        vm.prank(address(this));
        assertTrue(usdc.transfer(address(vault), vaultBalance));
        _setFeeClaimable(alice, claimableAmount);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(vault), vaultBalance, claimableAmount
            )
        );
        vault.claimFee(bob);

        assertEq(vault.feeClaimable(alice), claimableAmount);
        assertEq(usdc.balanceOf(bob), 0);
    }

    /// @notice scheduleFeePolicy 在费率 bps 超过 10000 时应回滚
    function test_scheduleFeePolicy_reverts_whenRateBpsExceedsDenominator() public {
        IVaultFee.FeePolicy memory policy = _zeroFeePolicy();
        policy.rates.entryFeeBps = 10_001;
        uint256 effectiveEpoch = vault.currentEpoch();

        vm.prank(admin);
        vm.expectRevert();
        vault.setFeePolicy(policy, effectiveEpoch);
    }

    /// @notice scheduleFeePolicy 不允许回填历史 epoch
    function test_scheduleFeePolicy_reverts_whenEffectiveEpochIsHistorical() public {
        IVaultFee.FeePolicy memory policy = _zeroFeePolicy();
        uint256 current = vault.currentEpoch();
        vm.warp(block.timestamp + SECONDS_PER_EPOCH);
        uint256 historicalEpoch = current;

        vm.prank(admin);
        vm.expectRevert();
        vault.setFeePolicy(policy, historicalEpoch);
    }

    /// @notice scheduleFeePolicy 在 split 总和超过 10000 时应回滚
    function test_scheduleFeePolicy_reverts_whenSplitSumExceedsDenominator() public {
        IVaultFee.FeePolicy memory policy = _zeroFeePolicy();
        policy.entrySplit = IVaultFee.SplitConfig({platformBps: 5000, referrerBps: 3000, managerBps: 3001});
        uint256 effectiveEpoch = vault.currentEpoch();

        vm.prank(admin);
        vm.expectRevert();
        vault.setFeePolicy(policy, effectiveEpoch);
    }

    /// @notice reserve 收款地址为必填，缺失时 scheduleFeePolicy 应回滚
    function test_scheduleFeePolicy_reverts_whenReserveRecipientMissing() public {
        IVaultFee.FeePolicy memory policy = _zeroFeePolicy();
        policy.recipients.reserve = address(0);
        uint256 effectiveEpoch = vault.currentEpoch();

        vm.prank(admin);
        vm.expectRevert();
        vault.setFeePolicy(policy, effectiveEpoch);
    }

    /// @notice 激活费率下存在平台分账但 platform 收款地址为空，scheduleFeePolicy 应回滚
    function test_scheduleFeePolicy_reverts_whenActiveSplitHasPlatformShareButPlatformMissing() public {
        IVaultFee.FeePolicy memory policy = _entryFeePolicy();
        policy.recipients.platform = address(0);
        uint256 effectiveEpoch = vault.currentEpoch();

        vm.prank(admin);
        vm.expectRevert();
        vault.setFeePolicy(policy, effectiveEpoch);
    }

    /// @notice setFeePolicy 的 effectiveEpoch 必须严格递增
    function test_setFeePolicy_reverts_whenEffectiveEpochIsNotStrictlyIncreasing() public {
        uint256 current = vault.currentEpoch();
        vm.prank(admin);
        vault.setFeePolicy(_zeroFeePolicy(), current + 2);

        vm.prank(admin);
        vm.expectRevert();
        vault.setFeePolicy(_zeroFeePolicy(), current + 2);
    }

    /// @notice 未配置 fee policy 时 finalizeEpoch 应回滚
    function test_finalizeEpoch_reverts_whenFeePolicyMissing() public {
        uint256 epoch = vault.currentEpoch();

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));
        vm.prank(operator);
        vm.expectRevert();
        vault.finalizeEpoch(epoch, 100e6);
    }

    /// @notice 管理费计算超过 pricingAum 时应被截断为 pricingAum
    function test_finalizeEpoch_clampsManagementFeeToPricingAum() public {
        uint256 sharesAtSettle = 100e18;
        uint256 totalAum = 1_000_000e6;
        deal(address(vault), manager, sharesAtSettle, true);

        IVaultFee.FeePolicy memory policy = _zeroFeePolicy();
        policy.rates.mgmtFeeAnnualBps = 10_000;
        policy.mgmtSplit = IVaultFee.SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 10_000});

        uint256 epoch = vault.currentEpoch() + 730;
        vm.prank(admin);
        vault.setFeePolicy(policy, epoch);

        vm.warp(block.timestamp + (731 * SECONDS_PER_EPOCH));
        vm.prank(operator);
        vault.finalizeEpoch(epoch, totalAum);

        IVaultSettlement.EpochSnapshot memory snapshot = vault.snapshotOf(epoch);
        assertEq(snapshot.totalAum, 0);
        assertEq(vault.feeClaimable(manager), totalAum);
        assertEq(vault.feeClaimable(admin), 0);
        assertEq(vault.feeClaimable(executor), 0);
    }

    /// @notice 当 NAV 未超过高水位时，不应收取业绩费
    function test_finalizeEpoch_doesNotChargePerformanceFee_whenNavNotAboveHighWaterMark() public {
        uint256 managerShares = 100e18;
        deal(address(vault), manager, managerShares, true);

        uint256 epoch1 = vault.currentEpoch();
        vm.prank(admin);
        vault.setFeePolicy(_performanceFeePolicy(), epoch1);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));
        vm.prank(operator);
        vault.finalizeEpoch(epoch1, 500e6);

        uint256 feeAfterEpoch1 = vault.feeClaimable(manager);
        assertEq(feeAfterEpoch1, 0);

        uint256 epoch2 = epoch1 + 1;
        vm.warp(block.timestamp + SECONDS_PER_EPOCH);
        vm.prank(operator);
        vault.finalizeEpoch(epoch2, 400e6);

        assertEq(vault.feeClaimable(manager), feeAfterEpoch1);
    }

    /// @notice fee policy 读函数应返回正确值，且 seq 在 finalize 后写入
    function test_feePolicyReadFunctions_returnExpectedValues() public {
        uint256 epoch = vault.currentEpoch() + 1;
        IVaultFee.FeePolicy memory policy = _zeroFeePolicy();

        vm.prank(admin);
        vault.setFeePolicy(policy, epoch);

        assertEq(vault.feePolicyCheckpointCount(), 1);
        IVaultFee.FeePolicyCheckpoint memory checkpoint = vault.feePolicyCheckpointAt(0);
        assertEq(checkpoint.effectiveEpoch, epoch);
        assertEq(checkpoint.policy.rates.entryFeeBps, policy.rates.entryFeeBps);
        assertEq(vault.feePolicySeq(epoch), 0);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));
        vm.prank(operator);
        vault.finalizeEpoch(epoch, 100e6);

        assertEq(vault.feePolicySeq(epoch), 1);
    }

    function _setFeeClaimable(address recipient, uint256 amount) internal {
        stdstore.target(address(vault)).sig("feeClaimable(address)").with_key(recipient).checked_write(amount);
    }

    function _entryFeePolicy() internal view returns (IVaultFee.FeePolicy memory policy) {
        policy = IVaultFee.FeePolicy({
            rates: IVaultFee.FeeRateConfig({
                entryFeeBps: 1000, exitFeeBps: 0, mgmtFeeAnnualBps: 0, performanceFeeBps: 0
            }),
            entrySplit: IVaultFee.SplitConfig({platformBps: 3000, referrerBps: 2000, managerBps: 5000}),
            exitSplit: IVaultFee.SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 10_000}),
            mgmtSplit: IVaultFee.SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 10_000}),
            performanceSplit: IVaultFee.SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 10_000}),
            recipients: IVaultFee.FeeRecipientConfig({platform: admin, manager: manager, reserve: executor})
        });
    }

    function _exitFeePolicy() internal view returns (IVaultFee.FeePolicy memory policy) {
        policy = IVaultFee.FeePolicy({
            rates: IVaultFee.FeeRateConfig({
                entryFeeBps: 0, exitFeeBps: 1000, mgmtFeeAnnualBps: 0, performanceFeeBps: 0
            }),
            entrySplit: IVaultFee.SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 10_000}),
            exitSplit: IVaultFee.SplitConfig({platformBps: 3000, referrerBps: 2000, managerBps: 5000}),
            mgmtSplit: IVaultFee.SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 10_000}),
            performanceSplit: IVaultFee.SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 10_000}),
            recipients: IVaultFee.FeeRecipientConfig({platform: admin, manager: manager, reserve: executor})
        });
    }

    function _mgmtFeePolicy() internal view returns (IVaultFee.FeePolicy memory policy) {
        policy = IVaultFee.FeePolicy({
            rates: IVaultFee.FeeRateConfig({
                entryFeeBps: 0, exitFeeBps: 0, mgmtFeeAnnualBps: 365, performanceFeeBps: 0
            }),
            entrySplit: IVaultFee.SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 10_000}),
            exitSplit: IVaultFee.SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 10_000}),
            mgmtSplit: IVaultFee.SplitConfig({platformBps: 3000, referrerBps: 0, managerBps: 7000}),
            performanceSplit: IVaultFee.SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 10_000}),
            recipients: IVaultFee.FeeRecipientConfig({platform: admin, manager: manager, reserve: executor})
        });
    }

    function _performanceFeePolicy() internal view returns (IVaultFee.FeePolicy memory policy) {
        policy = IVaultFee.FeePolicy({
            rates: IVaultFee.FeeRateConfig({
                entryFeeBps: 0, exitFeeBps: 0, mgmtFeeAnnualBps: 0, performanceFeeBps: 2000
            }),
            entrySplit: IVaultFee.SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 10_000}),
            exitSplit: IVaultFee.SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 10_000}),
            mgmtSplit: IVaultFee.SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 10_000}),
            performanceSplit: IVaultFee.SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 10_000}),
            recipients: IVaultFee.FeeRecipientConfig({platform: admin, manager: manager, reserve: executor})
        });
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
