// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../src/Vault.sol";
import {VaultErrors} from "../src/vault/VaultErrors.sol";
import {ReqStatus, FeePolicy, FeeRateConfig, SplitConfig, FeeRecipientConfig} from "../src/vault/VaultTypes.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {USDC} from "./mocks/USDC.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {VaultFactory} from "../src/VaultFactory.sol";

contract VaultTest is Test {
    uint256 public constant INITIAL_TIMESTAMP = 1767225600; // 2026-01-01 00:00:00 UTC
    uint256 public constant SECONDS_PER_EPOCH = 86400;
    uint256 internal constant SNAPSHOTS_MAPPING_SLOT = 13; // Vault.snapshots 的映射槽位（需与 Vault 存储布局保持一致）
    uint256 internal constant CLAIMABLE_ASSETS_MAPPING_SLOT = 8; // Vault.claimableAssets 的映射槽位（需与 Vault 存储布局保持一致）

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
    address bob = makeAddr("bob");

    event Claimed(address indexed investor, address indexed to, uint256 amount);
    event EpochFinalized(uint256 indexed epoch, uint256 totalAum, uint256 sharesAtSettle, uint256 navPerShare);

    function setUp() public {
        vm.warp(INITIAL_TIMESTAMP);
        usdc = new USDC();

        factory = _deployFactory(owner);
        vault = Vault(_createFund(factory, address(usdc), manager, admin, operator, executor, SECONDS_PER_EPOCH));
    }

    /// @notice 验证初始化后 secondsPerEpoch 被正确写入
    function test_initialize_setsSecondsPerEpoch() public view {
        assertEq(vault.secondsPerEpoch(), SECONDS_PER_EPOCH);
    }

    /// @notice 验证初始化后 epoch0 与 currentEpoch 计算正确
    function test_initialize_setsEpoch0() public view {
        uint256 epoch = block.timestamp / SECONDS_PER_EPOCH;
        assertEq(vault.epoch0(), epoch);
        assertEq(vault.currentEpoch(), epoch);
    }

    /// @notice 验证 admin/operator/executor 地址及角色绑定正确
    function test_initialize_setsRoleBindings() public view {
        assertEq(vault.admin(), admin);
        assertEq(vault.operator(), operator);
        assertEq(vault.executor(), executor);
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.OPERATOR_ROLE(), operator));
    }

    /// @notice 验证初始化后默认最小申购/赎回阈值
    function test_initialize_setsDefaultThresholds() public view {
        assertEq(vault.minDepositAmount(), 1);
        assertEq(vault.minRedeemShares(), 1);
    }

    /// @notice baseAsset 为零地址时应回滚
    function test_initialize_reverts_whenBaseAssetIsZero() public {
        VaultFactory localFactory = _deployFactory(owner);
        vm.prank(owner);
        vm.expectRevert(VaultErrors.ZeroAddress.selector);
        localFactory.createFund(
            "Alpha Fund Share", "AFS", address(0), manager, admin, operator, executor, SECONDS_PER_EPOCH
        );
    }

    /// @notice admin 为零地址时应回滚
    function test_initialize_reverts_whenAdminIsZero() public {
        VaultFactory localFactory = _deployFactory(owner);
        vm.prank(owner);
        vm.expectRevert(VaultErrors.ZeroAddress.selector);
        localFactory.createFund(
            "Alpha Fund Share", "AFS", address(usdc), manager, address(0), operator, executor, SECONDS_PER_EPOCH
        );
    }

    /// @notice operator 为零地址时应回滚
    function test_initialize_reverts_whenOperatorIsZero() public {
        VaultFactory localFactory = _deployFactory(owner);
        vm.prank(owner);
        vm.expectRevert(VaultErrors.ZeroAddress.selector);
        localFactory.createFund(
            "Alpha Fund Share", "AFS", address(usdc), manager, admin, address(0), executor, SECONDS_PER_EPOCH
        );
    }

    /// @notice executor 为零地址时应回滚
    function test_initialize_reverts_whenExecutorIsZero() public {
        VaultFactory localFactory = _deployFactory(owner);
        vm.prank(owner);
        vm.expectRevert(VaultErrors.ZeroAddress.selector);
        localFactory.createFund(
            "Alpha Fund Share", "AFS", address(usdc), manager, admin, operator, address(0), SECONDS_PER_EPOCH
        );
    }

    /// @notice secondsPerEpoch 为 0 时应回滚
    function test_initialize_reverts_whenSecondsPerEpochIsZero() public {
        VaultFactory localFactory = _deployFactory(owner);
        vm.prank(owner);
        vm.expectRevert(VaultErrors.InvalidSecondsPerEpoch.selector);
        localFactory.createFund("Alpha Fund Share", "AFS", address(usdc), manager, admin, operator, executor, 0);
    }

    /// @notice 代理初始化后再次调用 initialize 应回滚
    function test_initialize_cannotBeCalledTwice() public {
        vm.expectRevert();
        vault.initialize("Another Share", "ASH", address(usdc), admin, operator, executor, SECONDS_PER_EPOCH);
    }

    /// @notice 时间前进后 currentEpoch 应按周期递增
    function test_currentEpoch_increases_whenTimeMovesForward() public {
        uint256 epoch = vault.currentEpoch();

        vm.warp(block.timestamp + SECONDS_PER_EPOCH);
        assertEq(vault.currentEpoch(), epoch + 1);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH) + 123);
        assertEq(vault.currentEpoch(), epoch + 3);
    }

    /// @notice 禁止互荐：A 推荐 B 后，B 再推荐 A 应回滚
    function test_bindReferrer_reverts_whenMutualReferral() public {
        vm.prank(alice);
        vault.bindReferrer(bob);
        assertEq(vault.referrerOf(alice), bob);

        vm.prank(bob);
        vm.expectRevert(VaultErrors.CircularReferral.selector);
        vault.bindReferrer(alice);
        assertEq(vault.referrerOf(bob), address(0));
    }

    /// @notice 申购请求应记录为 Pending、完成资产转入，并在未绑定时写入推荐人
    function test_requestDeposit_recordsPendingAndTransfersBaseAsset() public {
        uint256 amount = 100e6;
        vm.prank(address(this));
        usdc.transfer(alice, amount);

        vm.prank(alice);
        usdc.approve(address(vault), amount);

        vm.prank(alice);
        (uint256 epoch, uint256 index) = vault.requestDeposit(amount, bob);

        (address investor, uint256 recordedAmount, ReqStatus status) = vault.depositRequests(epoch, index);
        assertEq(investor, alice);
        assertEq(recordedAmount, amount);
        assertEq(uint8(status), uint8(ReqStatus.Pending));
        assertEq(usdc.balanceOf(address(vault)), amount);
        assertEq(vault.referrerOf(alice), bob);
    }

    /// @notice 申购金额低于最小值时应回滚
    function test_requestDeposit_reverts_whenAmountBelowMinDeposit() public {
        vm.prank(alice);
        vm.expectRevert(VaultErrors.AmountTooSmall.selector);
        vault.requestDeposit(0, address(0));
    }

    /// @notice 推荐人仅首次绑定生效，后续 requestDeposit 传参不应覆盖
    function test_requestDeposit_referrerOnlyBindsWhenUnbound() public {
        uint256 amount = 100e6;
        vm.prank(address(this));
        usdc.transfer(alice, amount * 2);

        vm.startPrank(alice);
        usdc.approve(address(vault), amount * 2);
        vault.requestDeposit(amount, bob);
        vault.requestDeposit(amount, manager);
        vm.stopPrank();

        assertEq(vault.referrerOf(alice), bob);
    }

    /// @notice 申购时余额不足应回滚，且本次请求产生的状态变更应一并回滚
    function test_requestDeposit_reverts_whenInsufficientBalance() public {
        uint256 amount = 100e6;

        vm.prank(alice);
        usdc.approve(address(vault), amount);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, amount));
        vault.requestDeposit(amount, bob);

        assertEq(vault.referrerOf(alice), address(0));
    }

    /// @notice 赎回请求应记录为 Pending，并将份额锁定到 Vault
    function test_requestRedeem_recordsPendingAndLocksShares() public {
        uint256 shares = 10e18;
        deal(address(vault), alice, shares, true);

        vm.prank(alice);
        (uint256 epoch, uint256 index) = vault.requestRedeem(shares);

        (address investor, uint256 recordedShares, ReqStatus status) = vault.redeemRequests(epoch, index);
        assertEq(investor, alice);
        assertEq(recordedShares, shares);
        assertEq(uint8(status), uint8(ReqStatus.Pending));
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(address(vault)), shares);
    }

    /// @notice 赎回份额低于最小值时应回滚
    function test_requestRedeem_reverts_whenSharesBelowMinRedeem() public {
        vm.prank(alice);
        vm.expectRevert(VaultErrors.AmountTooSmall.selector);
        vault.requestRedeem(0);
    }

    /// @notice 撤销申购后应退款并标记 Canceled
    function test_cancelDeposit_returnsBaseAssetAndMarksCanceled() public {
        uint256 amount = 100e6;
        vm.prank(address(this));
        usdc.transfer(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        (uint256 epoch, uint256 index) = vault.requestDeposit(amount, bob);
        vault.cancelDeposit(epoch, index);
        vm.stopPrank();

        (address investor, uint256 recordedAmount, ReqStatus status) = vault.depositRequests(epoch, index);
        assertEq(investor, alice);
        assertEq(recordedAmount, amount);
        assertEq(uint8(status), uint8(ReqStatus.Canceled));
        assertEq(usdc.balanceOf(alice), amount);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    /// @notice 非请求所有者撤销申购应回滚
    function test_cancelDeposit_reverts_whenNotRequestOwner() public {
        uint256 amount = 100e6;
        vm.prank(address(this));
        usdc.transfer(alice, amount);

        vm.prank(alice);
        usdc.approve(address(vault), amount);
        vm.prank(alice);
        (uint256 epoch, uint256 index) = vault.requestDeposit(amount, bob);

        vm.prank(bob);
        vm.expectRevert(VaultErrors.NotRequestOwner.selector);
        vault.cancelDeposit(epoch, index);
    }

    /// @notice 已封账 epoch 的申购撤销应回滚
    function test_cancelDeposit_reverts_whenEpochAlreadyFinalized() public {
        uint256 amount = 100e6;
        vm.prank(address(this));
        usdc.transfer(alice, amount);

        vm.prank(alice);
        usdc.approve(address(vault), amount);
        vm.prank(alice);
        (uint256 epoch, uint256 index) = vault.requestDeposit(amount, bob);

        // EpochSnapshot.finalizedAt 位于 snapshots[epoch] 结构体的第 4 个 slot（offset = 3）
        bytes32 snapshotBaseSlot = keccak256(abi.encode(epoch, SNAPSHOTS_MAPPING_SLOT));
        bytes32 finalizedAtSlot = bytes32(uint256(snapshotBaseSlot) + 3);
        vm.store(address(vault), finalizedAtSlot, bytes32(uint256(1)));

        vm.prank(alice);
        vm.expectRevert(VaultErrors.EpochAlreadyFinalized.selector);
        vault.cancelDeposit(epoch, index);
    }

    /// @notice 撤销赎回后应解锁份额并标记 Canceled
    function test_cancelRedeem_unlocksSharesAndMarksCanceled() public {
        uint256 shares = 10e18;
        deal(address(vault), alice, shares, true);

        vm.startPrank(alice);
        (uint256 epoch, uint256 index) = vault.requestRedeem(shares);
        vault.cancelRedeem(epoch, index);
        vm.stopPrank();

        (address investor, uint256 recordedShares, ReqStatus status) = vault.redeemRequests(epoch, index);
        assertEq(investor, alice);
        assertEq(recordedShares, shares);
        assertEq(uint8(status), uint8(ReqStatus.Canceled));
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.balanceOf(address(vault)), 0);
    }

    /// @notice 非请求所有者撤销赎回应回滚
    function test_cancelRedeem_reverts_whenNotRequestOwner() public {
        uint256 shares = 10e18;
        deal(address(vault), alice, shares, true);

        vm.prank(alice);
        (uint256 epoch, uint256 index) = vault.requestRedeem(shares);

        vm.prank(bob);
        vm.expectRevert(VaultErrors.NotRequestOwner.selector);
        vault.cancelRedeem(epoch, index);
    }

    /// @notice 已封账 epoch 的赎回撤销应回滚
    function test_cancelRedeem_reverts_whenEpochAlreadyFinalized() public {
        uint256 shares = 10e18;
        deal(address(vault), alice, shares, true);

        vm.prank(alice);
        (uint256 epoch, uint256 index) = vault.requestRedeem(shares);

        // EpochSnapshot.finalizedAt 位于 snapshots[epoch] 结构体的第 4 个 slot（offset = 3）
        bytes32 snapshotBaseSlot = keccak256(abi.encode(epoch, SNAPSHOTS_MAPPING_SLOT));
        bytes32 finalizedAtSlot = bytes32(uint256(snapshotBaseSlot) + 3);
        vm.store(address(vault), finalizedAtSlot, bytes32(uint256(1)));

        vm.prank(alice);
        vm.expectRevert(VaultErrors.EpochAlreadyFinalized.selector);
        vault.cancelRedeem(epoch, index);
    }

    /// @notice 未封账 epoch 调用 settleDeposits 应回滚
    function test_settleDeposits_reverts_whenEpochNotFinalized() public {
        uint256 epoch = vault.currentEpoch();

        vm.prank(operator);
        vm.expectRevert(VaultErrors.InvalidFinalizeEpoch.selector);
        vault.settleDeposits(epoch, 1);
    }

    /// @notice maxCount 为 0 时 settleDeposits 应回滚
    function test_settleDeposits_reverts_whenMaxCountIsZero() public {
        uint256 epoch = vault.currentEpoch();

        vm.prank(operator);
        vm.expectRevert(VaultErrors.InvalidMaxCount.selector);
        vault.settleDeposits(epoch, 0);
    }

    /// @notice 申购批结算应按 NAV 铸币、跳过非 Pending 请求并推进游标
    function test_settleDeposits_processesBatchAndUpdatesCursor() public {
        uint256 aliceAmount = 100e6;
        uint256 bobAmount = 50e6;

        vm.prank(address(this));
        usdc.transfer(alice, aliceAmount);
        vm.prank(address(this));
        usdc.transfer(bob, bobAmount);

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
        vault.scheduleFeePolicy(_zeroFeePolicy(), epoch);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));

        vm.prank(operator);
        vault.finalizeEpoch(epoch, totalAum);

        uint256 expectedPricingAum = totalAum - vault.netRequestedDepositAssets(epoch);
        uint256 expectedNavPerShare = (expectedPricingAum * 1e18) / sharesAtSettle;
        uint256 expectedAliceShares = (aliceAmount * 1e18) / expectedNavPerShare;

        vm.prank(operator);
        vault.settleDeposits(epoch, 1);

        (,, ReqStatus aliceStatus) = vault.depositRequests(epoch, aliceIndex);
        (,, ReqStatus bobStatus) = vault.depositRequests(epoch, bobIndex);
        assertEq(uint8(aliceStatus), uint8(ReqStatus.Settled));
        assertEq(uint8(bobStatus), uint8(ReqStatus.Canceled));
        assertEq(vault.balanceOf(alice), expectedAliceShares);

        (uint256 nextDeposit, uint256 nextRedeem, bool depositsDone, bool redeemsDone) = vault.cursors(epoch);
        assertEq(nextDeposit, 1);
        assertEq(nextRedeem, 0);
        assertFalse(depositsDone);
        assertFalse(redeemsDone);

        vm.prank(operator);
        vault.settleDeposits(epoch, 10);

        (nextDeposit, nextRedeem, depositsDone, redeemsDone) = vault.cursors(epoch);
        assertEq(nextDeposit, 2);
        assertEq(nextRedeem, 0);
        assertTrue(depositsDone);
        assertFalse(redeemsDone);

        vm.prank(operator);
        vm.expectRevert(VaultErrors.DepositsSettlementCompleted.selector);
        vault.settleDeposits(epoch, 1);
    }

    /// @notice settleDeposits 应按 ENTRY 费率扣费，并把推荐人分账记入 feeClaimable
    function test_settleDeposits_appliesEntryFeeAndAccruesFeeClaimable_withReferrer() public {
        uint256 managerShares = 200e18;
        uint256 depositAmount = 100e6;
        uint256 totalAum = 500e6;
        deal(address(vault), manager, managerShares, true);

        vm.prank(address(this));
        usdc.transfer(alice, depositAmount);
        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        (uint256 epoch,) = vault.requestDeposit(depositAmount, bob);
        vm.stopPrank();

        vm.prank(admin);
        vault.scheduleFeePolicy(_entryFeePolicy(), epoch);

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
        assertEq(vault.feeClaimableOf(admin), (entryFee * 3000) / 10_000);
        assertEq(vault.feeClaimableOf(bob), (entryFee * 2000) / 10_000);
        assertEq(vault.feeClaimableOf(manager), (entryFee * 5000) / 10_000);
        assertEq(vault.feeClaimableOf(executor), 0);
    }

    /// @notice 无推荐人时，推荐人分账应回流到 reserve
    function test_settleDeposits_appliesEntryFeeAndRoutesReferrerShareToReserve_whenNoReferrer() public {
        uint256 managerShares = 200e18;
        uint256 depositAmount = 100e6;
        uint256 totalAum = 500e6;
        deal(address(vault), manager, managerShares, true);

        vm.prank(address(this));
        usdc.transfer(alice, depositAmount);
        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        (uint256 epoch,) = vault.requestDeposit(depositAmount, address(0));
        vm.stopPrank();

        vm.prank(admin);
        vault.scheduleFeePolicy(_entryFeePolicy(), epoch);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));
        vm.prank(operator);
        vault.finalizeEpoch(epoch, totalAum);

        uint256 entryFee = (depositAmount * 1000) / 10_000;
        vm.prank(operator);
        vault.settleDeposits(epoch, 10);

        assertEq(vault.feeClaimableOf(admin), (entryFee * 3000) / 10_000);
        assertEq(vault.feeClaimableOf(manager), (entryFee * 5000) / 10_000);
        assertEq(vault.feeClaimableOf(executor), (entryFee * 2000) / 10_000);
        assertEq(vault.feeClaimableOf(bob), 0);
    }

    /// @notice 未封账 epoch 调用 settleRedeems 应回滚
    function test_settleRedeems_reverts_whenEpochNotFinalized() public {
        uint256 epoch = vault.currentEpoch();

        vm.prank(operator);
        vm.expectRevert(VaultErrors.InvalidFinalizeEpoch.selector);
        vault.settleRedeems(epoch, 1);
    }

    /// @notice maxCount 为 0 时 settleRedeems 应回滚
    function test_settleRedeems_reverts_whenMaxCountIsZero() public {
        uint256 epoch = vault.currentEpoch();

        vm.prank(operator);
        vm.expectRevert(VaultErrors.InvalidMaxCount.selector);
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
        vault.scheduleFeePolicy(_zeroFeePolicy(), epoch);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));

        vm.prank(operator);
        vault.finalizeEpoch(epoch, totalAum);

        uint256 expectedNavPerShare = (totalAum * 1e18) / vault.totalSupply();
        uint256 expectedClaimableAssets = (aliceShares * expectedNavPerShare) / 1e18;

        vm.prank(operator);
        vault.settleRedeems(epoch, 1);

        (,, ReqStatus aliceStatus) = vault.redeemRequests(epoch, aliceIndex);
        (,, ReqStatus bobStatus) = vault.redeemRequests(epoch, bobIndex);
        assertEq(uint8(aliceStatus), uint8(ReqStatus.Settled));
        assertEq(uint8(bobStatus), uint8(ReqStatus.Canceled));
        assertEq(vault.claimableAssets(alice), expectedClaimableAssets);
        assertEq(vault.balanceOf(address(vault)), 0);

        (uint256 nextDeposit, uint256 nextRedeem, bool depositsDone, bool redeemsDone) = vault.cursors(epoch);
        assertEq(nextDeposit, 0);
        assertEq(nextRedeem, 1);
        assertFalse(depositsDone);
        assertFalse(redeemsDone);

        vm.prank(operator);
        vault.settleRedeems(epoch, 10);

        (nextDeposit, nextRedeem, depositsDone, redeemsDone) = vault.cursors(epoch);
        assertEq(nextDeposit, 0);
        assertEq(nextRedeem, 2);
        assertFalse(depositsDone);
        assertTrue(redeemsDone);

        vm.prank(operator);
        vm.expectRevert(VaultErrors.RedeemsSettlementCompleted.selector);
        vault.settleRedeems(epoch, 1);
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
        vault.scheduleFeePolicy(_exitFeePolicy(), epoch);

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
        assertEq(vault.feeClaimableOf(admin), (exitFee * 3000) / 10_000);
        assertEq(vault.feeClaimableOf(bob), (exitFee * 2000) / 10_000);
        assertEq(vault.feeClaimableOf(manager), (exitFee * 5000) / 10_000);
        assertEq(vault.feeClaimableOf(executor), 0);
    }

    /// @notice 非 operator 调用 transferToExecutor 应回滚
    function test_transferToExecutor_reverts_whenCalledByNonOperator() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.transferToExecutor(1);
    }

    /// @notice operator 调用 transferToExecutor 应将 baseAsset 转入 executor
    function test_transferToExecutor_transfersBaseAssetToExecutor() public {
        uint256 amount = 123e6;
        vm.prank(address(this));
        usdc.transfer(address(vault), amount);

        uint256 beforeVault = usdc.balanceOf(address(vault));
        uint256 beforeExecutor = usdc.balanceOf(executor);

        vm.prank(operator);
        vault.transferToExecutor(amount);

        assertEq(usdc.balanceOf(address(vault)), beforeVault - amount);
        assertEq(usdc.balanceOf(executor), beforeExecutor + amount);
    }

    /// @notice claim 应转出可领取资产并触发 Claimed
    function test_claim_transfersClaimableAssetsAndEmitsClaimed() public {
        uint256 amount = 100e6;
        vm.prank(address(this));
        usdc.transfer(address(vault), amount);
        _setClaimableAsset(alice, amount);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Claimed(alice, bob, amount);
        uint256 claimedAmount = vault.claim(bob);

        assertEq(claimedAmount, amount);
        assertEq(vault.claimableAssets(alice), 0);
        assertEq(usdc.balanceOf(bob), amount);
    }

    /// @notice claim 在无可领取资产时应回滚
    function test_claim_reverts_whenNoClaimableAssets() public {
        vm.prank(alice);
        vm.expectRevert(VaultErrors.NoClaimableAssets.selector);
        vault.claim(bob);
    }

    /// @notice claim 的收款地址为零地址时应回滚
    function test_claim_reverts_whenToIsZeroAddress() public {
        _setClaimableAsset(alice, 1);
        vm.prank(alice);
        vm.expectRevert(VaultErrors.ZeroAddress.selector);
        vault.claim(address(0));
    }

    /// @notice 当 Vault 持有的 baseAsset 不足以覆盖可领取金额时，claim 应回滚
    function test_claim_reverts_whenVaultBaseAssetInsufficient() public {
        uint256 claimableAmount = 100e6;
        uint256 vaultBalance = 50e6;
        vm.prank(address(this));
        usdc.transfer(address(vault), vaultBalance);
        _setClaimableAsset(alice, claimableAmount);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(vault), vaultBalance, claimableAmount
            )
        );
        vault.claim(bob);

        // 转账失败应导致整笔交易回滚，claimable 余额不应被清零
        assertEq(vault.claimableAssets(alice), claimableAmount);
        assertEq(usdc.balanceOf(bob), 0);
    }

    /// @notice 非 operator 调用 finalizeEpoch 应回滚
    function test_finalizeEpoch_reverts_whenCalledByNonOperator() public {
        uint256 epoch = vault.currentEpoch() - 1;
        vm.prank(alice);
        vm.expectRevert();
        vault.finalizeEpoch(epoch, 100e6);
    }

    /// @notice 当前或未来 epoch 封账应回滚
    function test_finalizeEpoch_reverts_forCurrentOrFutureEpoch() public {
        uint256 current = vault.currentEpoch();

        vm.prank(operator);
        vm.expectRevert(VaultErrors.InvalidFinalizeEpoch.selector);
        vault.finalizeEpoch(current, 100e6);

        vm.prank(operator);
        vm.expectRevert(VaultErrors.InvalidFinalizeEpoch.selector);
        vault.finalizeEpoch(current + 1, 100e6);
    }

    /// @notice 同一 epoch 二次封账应回滚
    function test_finalizeEpoch_reverts_whenCalledTwiceForSameEpoch() public {
        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));
        uint256 epoch = vault.currentEpoch() - 1;
        vm.prank(operator);
        vault.finalizeEpoch(epoch, 100e6);

        vm.prank(operator);
        vm.expectRevert(VaultErrors.EpochAlreadyFinalized.selector);
        vault.finalizeEpoch(epoch, 200e6);
    }

    /// @notice 封账应写入快照并触发事件
    function test_finalizeEpoch_storesSnapshotAndEmitsEvent() public {
        uint256 sharesAtSettle = 200e18;
        uint256 totalAum = 500e6;
        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));
        uint256 epoch = vault.currentEpoch() - 1;
        uint256 expectedNavPerShare = (totalAum * 1e18) / sharesAtSettle;

        deal(address(vault), alice, sharesAtSettle, true);

        vm.prank(operator);
        vm.expectEmit(true, true, true, true);
        emit EpochFinalized(epoch, totalAum, sharesAtSettle, expectedNavPerShare);
        vault.finalizeEpoch(epoch, totalAum);

        (uint256 storedAum, uint256 storedShares, uint256 storedNav, uint256 finalizedAt) = vault.snapshots(epoch);
        assertEq(storedAum, totalAum);
        assertEq(storedShares, sharesAtSettle);
        assertEq(storedNav, expectedNavPerShare);
        assertEq(finalizedAt, block.timestamp);
    }

    /// @notice totalAum 小于当期净申购额时 finalizeEpoch 应回滚
    function test_finalizeEpoch_reverts_whenTotalAumLessThanNetRequestedDeposits() public {
        uint256 depositAmount = 100e6;
        vm.prank(address(this));
        usdc.transfer(alice, depositAmount);

        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        (uint256 epoch,) = vault.requestDeposit(depositAmount, address(0));
        vm.stopPrank();

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));

        vm.prank(operator);
        vm.expectRevert(VaultErrors.InvalidTotalAum.selector);
        vault.finalizeEpoch(epoch, depositAmount - 1);
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

    function _setClaimableAsset(address investor, uint256 amount) internal {
        bytes32 slot = keccak256(abi.encode(investor, CLAIMABLE_ASSETS_MAPPING_SLOT));
        vm.store(address(vault), slot, bytes32(amount));
    }

    function _entryFeePolicy() internal view returns (FeePolicy memory policy) {
        policy = FeePolicy({
            rates: FeeRateConfig({entryFeeBps: 1000, exitFeeBps: 0, mgmtFeeAnnualBps: 0, performanceFeeBps: 0}),
            entrySplit: SplitConfig({platformBps: 3000, referrerBps: 2000, managerBps: 5000}),
            exitSplit: SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 10_000}),
            mgmtSplit: SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 10_000}),
            performanceSplit: SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 10_000}),
            recipients: FeeRecipientConfig({platform: admin, manager: manager, reserve: executor})
        });
    }

    function _exitFeePolicy() internal view returns (FeePolicy memory policy) {
        policy = FeePolicy({
            rates: FeeRateConfig({entryFeeBps: 0, exitFeeBps: 1000, mgmtFeeAnnualBps: 0, performanceFeeBps: 0}),
            entrySplit: SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 10_000}),
            exitSplit: SplitConfig({platformBps: 3000, referrerBps: 2000, managerBps: 5000}),
            mgmtSplit: SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 10_000}),
            performanceSplit: SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 10_000}),
            recipients: FeeRecipientConfig({platform: admin, manager: manager, reserve: executor})
        });
    }

    function _zeroFeePolicy() internal view returns (FeePolicy memory policy) {
        policy = FeePolicy({
            rates: FeeRateConfig({entryFeeBps: 0, exitFeeBps: 0, mgmtFeeAnnualBps: 0, performanceFeeBps: 0}),
            entrySplit: SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 0}),
            exitSplit: SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 0}),
            mgmtSplit: SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 0}),
            performanceSplit: SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 0}),
            recipients: FeeRecipientConfig({platform: admin, manager: manager, reserve: executor})
        });
    }

    // TODO(vault): 待业务函数实现后补充以下测试（函数名预留 + 中文说明）
    // function test_requestDeposit_reverts_whenDepositPaused() public {} // 申购暂停时应回滚
    // function test_requestRedeem_reverts_whenRedeemPaused() public {} // 赎回暂停时应回滚
    // function test_settleDeposits_processesBatchAndUpdatesCursor() public {} // 申购批结算应推进游标并更新状态
    // function test_settleRedeems_processesBatchAndUpdatesCursor() public {} // 赎回批结算应推进游标并更新状态
    // function test_transferToExecutor_reverts_whenCalledByNonOperator() public {} // 非 operator 划转执行钱包应回滚
    // function test_transferToExecutor_transfersBaseAssetToExecutor() public {} // operator 划转执行钱包应成功转账
    // function test_pauseDeposit_onlyAdminCanToggle() public {} // 仅 admin 可切换申购暂停状态
    // function test_pauseRedeem_onlyAdminCanToggle() public {} // 仅 admin 可切换赎回暂停状态
    // function test_depositRequestCount_returnsPerEpochLength() public {} // depositRequestCount 应返回对应 epoch 请求数
    // function test_redeemRequestCount_returnsPerEpochLength() public {} // redeemRequestCount 应返回对应 epoch 请求数
}
