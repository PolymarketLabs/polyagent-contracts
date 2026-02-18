// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {VaultTestBase} from "./shared/VaultTestBase.sol";
import {IVaultUser} from "../src/interfaces/IVaultUser.sol";
import {IVaultFee} from "../src/interfaces/IVaultFee.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract VaultUserTest is VaultTestBase {
    using stdStorage for StdStorage;

    uint256 public constant INITIAL_TIMESTAMP = 1767225600; // 2026-01-01 00:00:00 UTC
    uint256 public constant SECONDS_PER_EPOCH = 86400;
    uint256 public constant INITIAL_MIN_DEPOSIT_AMOUNT = 1;
    uint256 public constant INITIAL_MIN_REDEEM_SHARES = 1;

    event Claimed(address indexed investor, address indexed to, uint256 amount);
    event MinDepositAmountUpdated(uint256 previousValue, uint256 newValue);
    event MinRedeemSharesUpdated(uint256 previousValue, uint256 newValue);

    function setUp() public {
        _setUpVaultFixture(INITIAL_TIMESTAMP, SECONDS_PER_EPOCH, INITIAL_MIN_DEPOSIT_AMOUNT, INITIAL_MIN_REDEEM_SHARES);
    }

    /// @notice 验证初始化后默认最小申购/赎回阈值
    function test_initialize_setsDefaultThresholds() public view {
        assertEq(vault.minDepositAmount(), 1);
        assertEq(vault.minRedeemShares(), 1);
    }

    /// @notice 禁止互荐：A 推荐 B 后，B 再推荐 A 应回滚
    function test_bindReferrer_reverts_whenMutualReferral() public {
        vm.prank(alice);
        vault.bindReferrer(bob);
        assertEq(vault.referrerOf(alice), bob);

        vm.prank(bob);
        vm.expectRevert();
        vault.bindReferrer(alice);
        assertEq(vault.referrerOf(bob), address(0));
    }

    /// @notice 禁止自荐：investor 与 referrer 相同应回滚
    function test_bindReferrer_reverts_whenSelfReferral() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.bindReferrer(alice);
    }

    /// @notice 申购请求应记录为 Pending、完成资产转入，并在未绑定时写入推荐人
    function test_requestDeposit_recordsPendingAndTransfersBaseAsset() public {
        uint256 amount = 100e6;
        vm.prank(address(this));
        assertTrue(usdc.transfer(alice, amount));

        vm.prank(alice);
        usdc.approve(address(vault), amount);

        vm.prank(alice);
        (uint256 epoch, uint256 index) = vault.requestDeposit(amount, bob);

        (address investor, uint256 recordedAmount, IVaultUser.ReqStatus status) = vault.depositRequestAt(epoch, index);
        assertEq(investor, alice);
        assertEq(recordedAmount, amount);
        assertEq(uint8(status), uint8(IVaultUser.ReqStatus.Pending));
        assertEq(usdc.balanceOf(address(vault)), amount);
        assertEq(vault.referrerOf(alice), bob);
    }

    /// @notice 申购金额低于最小值时应回滚
    function test_requestDeposit_reverts_whenAmountBelowMinDeposit() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.requestDeposit(0, address(0));
    }

    /// @notice 推荐人仅首次绑定生效，后续 requestDeposit 传参不应覆盖
    function test_requestDeposit_referrerOnlyBindsWhenUnbound() public {
        uint256 amount = 100e6;
        vm.prank(address(this));
        assertTrue(usdc.transfer(alice, amount * 2));

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

        (address investor, uint256 recordedShares, IVaultUser.ReqStatus status) = vault.redeemRequestAt(epoch, index);
        assertEq(investor, alice);
        assertEq(recordedShares, shares);
        assertEq(uint8(status), uint8(IVaultUser.ReqStatus.Pending));
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(address(vault)), shares);
    }

    /// @notice 赎回份额低于最小值时应回滚
    function test_requestRedeem_reverts_whenSharesBelowMinRedeem() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.requestRedeem(0);
    }

    /// @notice depositRequestCount 应返回指定 epoch 的申购请求条数
    function test_depositRequestCount_returnsPerEpochLength() public {
        uint256 aliceAmount = 100e6;
        uint256 bobAmount = 50e6;

        vm.prank(address(this));
        assertTrue(usdc.transfer(alice, aliceAmount));
        vm.prank(address(this));
        assertTrue(usdc.transfer(bob, bobAmount));

        vm.startPrank(alice);
        usdc.approve(address(vault), aliceAmount);
        (uint256 epoch,) = vault.requestDeposit(aliceAmount, address(0));
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(vault), bobAmount);
        vault.requestDeposit(bobAmount, address(0));
        vm.stopPrank();

        assertEq(vault.depositRequestCount(epoch), 2);
        assertEq(vault.depositRequestCount(epoch + 1), 0);
    }

    /// @notice redeemRequestCount 应返回指定 epoch 的赎回请求条数
    function test_redeemRequestCount_returnsPerEpochLength() public {
        uint256 aliceShares = 10e18;
        uint256 bobShares = 5e18;
        deal(address(vault), alice, aliceShares, true);
        deal(address(vault), bob, bobShares, true);

        vm.prank(alice);
        (uint256 epoch,) = vault.requestRedeem(aliceShares);

        vm.prank(bob);
        vault.requestRedeem(bobShares);

        assertEq(vault.redeemRequestCount(epoch), 2);
        assertEq(vault.redeemRequestCount(epoch + 1), 0);
    }

    /// @notice netRequestedRedeemShares 应返回指定 epoch 的净赎回份额
    function test_netRequestedRedeemShares_returnsPerEpochNetAmount() public {
        uint256 aliceShares = 10e18;
        uint256 bobShares = 5e18;
        deal(address(vault), alice, aliceShares, true);
        deal(address(vault), bob, bobShares, true);

        vm.prank(alice);
        (uint256 epoch,) = vault.requestRedeem(aliceShares);

        vm.prank(bob);
        (, uint256 bobIndex) = vault.requestRedeem(bobShares);

        assertEq(vault.netRequestedRedeemShares(epoch), aliceShares + bobShares);

        vm.prank(bob);
        vault.cancelRedeem(epoch, bobIndex);

        assertEq(vault.netRequestedRedeemShares(epoch), aliceShares);
    }

    /// @notice 撤销申购后应退款并标记 Canceled
    function test_cancelDeposit_returnsBaseAssetAndMarksCanceled() public {
        uint256 amount = 100e6;
        vm.prank(address(this));
        assertTrue(usdc.transfer(alice, amount));

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        (uint256 epoch, uint256 index) = vault.requestDeposit(amount, bob);
        vault.cancelDeposit(epoch, index);
        vm.stopPrank();

        (address investor, uint256 recordedAmount, IVaultUser.ReqStatus status) = vault.depositRequestAt(epoch, index);
        assertEq(investor, alice);
        assertEq(recordedAmount, amount);
        assertEq(uint8(status), uint8(IVaultUser.ReqStatus.Canceled));
        assertEq(usdc.balanceOf(alice), amount);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    /// @notice 非请求所有者撤销申购应回滚
    function test_cancelDeposit_reverts_whenNotRequestOwner() public {
        uint256 amount = 100e6;
        vm.prank(address(this));
        assertTrue(usdc.transfer(alice, amount));

        vm.prank(alice);
        usdc.approve(address(vault), amount);
        vm.prank(alice);
        (uint256 epoch, uint256 index) = vault.requestDeposit(amount, bob);

        vm.prank(bob);
        vm.expectRevert();
        vault.cancelDeposit(epoch, index);
    }

    /// @notice 已取消请求再次撤销应回滚（非 Pending）
    function test_cancelDeposit_reverts_whenRequestStatusIsNotPending() public {
        uint256 amount = 100e6;
        vm.prank(address(this));
        assertTrue(usdc.transfer(alice, amount));

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        (uint256 epoch, uint256 index) = vault.requestDeposit(amount, bob);
        vault.cancelDeposit(epoch, index);
        vm.expectRevert();
        vault.cancelDeposit(epoch, index);
        vm.stopPrank();
    }

    /// @notice 已封账 epoch 的申购撤销应回滚
    function test_cancelDeposit_reverts_whenEpochAlreadyFinalized() public {
        uint256 amount = 100e6;
        vm.prank(address(this));
        assertTrue(usdc.transfer(alice, amount));

        vm.prank(alice);
        usdc.approve(address(vault), amount);
        vm.prank(alice);
        (uint256 epoch, uint256 index) = vault.requestDeposit(amount, bob);

        vm.prank(admin);
        vault.setFeePolicy(_zeroFeePolicy(), epoch);

        vm.warp(block.timestamp + SECONDS_PER_EPOCH);
        vm.prank(operator);
        vault.finalizeEpoch(epoch, amount);

        vm.prank(alice);
        vm.expectRevert();
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

        (address investor, uint256 recordedShares, IVaultUser.ReqStatus status) = vault.redeemRequestAt(epoch, index);
        assertEq(investor, alice);
        assertEq(recordedShares, shares);
        assertEq(uint8(status), uint8(IVaultUser.ReqStatus.Canceled));
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
        vm.expectRevert();
        vault.cancelRedeem(epoch, index);
    }

    /// @notice 已取消请求再次撤销应回滚（非 Pending）
    function test_cancelRedeem_reverts_whenRequestStatusIsNotPending() public {
        uint256 shares = 10e18;
        deal(address(vault), alice, shares, true);

        vm.startPrank(alice);
        (uint256 epoch, uint256 index) = vault.requestRedeem(shares);
        vault.cancelRedeem(epoch, index);
        vm.expectRevert();
        vault.cancelRedeem(epoch, index);
        vm.stopPrank();
    }

    /// @notice setMinDepositAmount 应更新阈值并触发事件
    function test_setMinDepositAmount_updatesValueAndEmitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit MinDepositAmountUpdated(INITIAL_MIN_DEPOSIT_AMOUNT, 100e6);
        vault.setMinDepositAmount(100e6);

        assertEq(vault.minDepositAmount(), 100e6);
    }

    /// @notice setMinDepositAmount 传入 0 应回滚
    function test_setMinDepositAmount_reverts_whenZero() public {
        vm.prank(admin);
        vm.expectRevert();
        vault.setMinDepositAmount(0);
    }

    /// @notice setMinRedeemShares 应更新阈值并触发事件
    function test_setMinRedeemShares_updatesValueAndEmitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit MinRedeemSharesUpdated(INITIAL_MIN_REDEEM_SHARES, 2e18);
        vault.setMinRedeemShares(2e18);

        assertEq(vault.minRedeemShares(), 2e18);
    }

    /// @notice setMinRedeemShares 传入 0 应回滚
    function test_setMinRedeemShares_reverts_whenZero() public {
        vm.prank(admin);
        vm.expectRevert();
        vault.setMinRedeemShares(0);
    }

    /// @notice 已封账 epoch 的赎回撤销应回滚
    function test_cancelRedeem_reverts_whenEpochAlreadyFinalized() public {
        uint256 shares = 10e18;
        deal(address(vault), alice, shares, true);

        vm.prank(alice);
        (uint256 epoch, uint256 index) = vault.requestRedeem(shares);

        vm.prank(admin);
        vault.setFeePolicy(_zeroFeePolicy(), epoch);

        vm.warp(block.timestamp + SECONDS_PER_EPOCH);
        vm.prank(operator);
        vault.finalizeEpoch(epoch, 100e6);

        vm.prank(alice);
        vm.expectRevert();
        vault.cancelRedeem(epoch, index);
    }

    /// @notice claim 应转出可领取资产并触发 Claimed
    function test_claim_transfersClaimableAssetsAndEmitsClaimed() public {
        uint256 amount = 100e6;
        vm.prank(address(this));
        assertTrue(usdc.transfer(address(vault), amount));
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
        vm.expectRevert();
        vault.claim(bob);
    }

    /// @notice claim 的收款地址为零地址时应回滚
    function test_claim_reverts_whenToIsZeroAddress() public {
        _setClaimableAsset(alice, 1);
        vm.prank(alice);
        vm.expectRevert();
        vault.claim(address(0));
    }

    /// @notice 当 Vault 持有的 baseAsset 不足以覆盖可领取金额时，claim 应回滚
    function test_claim_reverts_whenVaultBaseAssetInsufficient() public {
        uint256 claimableAmount = 100e6;
        uint256 vaultBalance = 50e6;
        vm.prank(address(this));
        assertTrue(usdc.transfer(address(vault), vaultBalance));
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

    function _setClaimableAsset(address investor, uint256 amount) internal {
        stdstore.target(address(vault)).sig("claimableAssets(address)").with_key(investor).checked_write(amount);
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
