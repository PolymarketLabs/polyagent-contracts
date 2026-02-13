// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../src/Vault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {ReqStatus, FeePolicy, FeeRateConfig, SplitConfig, FeeRecipientConfig} from "../src/vault/VaultTypes.sol";
import {USDC} from "./mocks/USDC.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract VaultFlowsTest is Test {
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
    address bob = makeAddr("bob");

    function setUp() public {
        vm.warp(INITIAL_TIMESTAMP);
        usdc = new USDC();

        factory = _deployFactory(owner);
        vault = Vault(_createFund(factory, address(usdc), manager, admin, operator, executor, SECONDS_PER_EPOCH));

        vm.prank(admin);
        vault.scheduleFeePolicy(_zeroFeePolicy(), 0);
    }

    /// @notice 端到端：申购 -> 封账 -> 申购结算
    function test_flow_deposit_finalize_settleDeposits_endToEnd() public {
        uint256 managerShares = 200e18;
        uint256 depositAmount = 100e6;
        uint256 totalAum = 500e6;
        deal(address(vault), manager, managerShares, true);

        vm.prank(address(this));
        usdc.transfer(alice, depositAmount);
        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmount);
        (uint256 epoch, uint256 index) = vault.requestDeposit(depositAmount, address(0));
        vm.stopPrank();

        vm.prank(admin);
        vault.scheduleFeePolicy(_zeroFeePolicy(), epoch);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));
        vm.prank(operator);
        vault.finalizeEpoch(epoch, totalAum);

        uint256 pricingAum = totalAum - vault.netRequestedDepositAssets(epoch);
        uint256 expectedNavPerShare = (pricingAum * 1e18) / managerShares;
        uint256 expectedShares = (depositAmount * 1e18) / expectedNavPerShare;

        vm.prank(operator);
        vault.settleDeposits(epoch, 10);

        (, uint256 storedSharesAtSettle, uint256 storedNavPerShare,) = vault.snapshots(epoch);
        (,, ReqStatus status) = vault.depositRequests(epoch, index);
        (uint256 nextDeposit,, bool depositsDone,) = vault.cursors(epoch);
        assertEq(storedSharesAtSettle, managerShares);
        assertEq(storedNavPerShare, expectedNavPerShare);
        assertEq(uint8(status), uint8(ReqStatus.Settled));
        assertEq(vault.balanceOf(alice), expectedShares);
        assertEq(nextDeposit, 1);
        assertTrue(depositsDone);
    }

    /// @notice 端到端：A 申购 + B 赎回 -> 封账 -> 结算 -> B 领取
    function test_flow_deposit_and_redeem_finalize_settle_then_claim() public {
        uint256 managerShares = 180e18;
        uint256 bobShares = 20e18;
        uint256 aliceDeposit = 100e6;
        uint256 totalAum = 1_100e6;

        deal(address(vault), manager, managerShares, true);
        deal(address(vault), bob, bobShares, true);

        vm.prank(address(this));
        usdc.transfer(alice, aliceDeposit);
        vm.startPrank(alice);
        usdc.approve(address(vault), aliceDeposit);
        (uint256 epoch, uint256 depositIndex) = vault.requestDeposit(aliceDeposit, address(0));
        vm.stopPrank();

        vm.prank(bob);
        (, uint256 redeemIndex) = vault.requestRedeem(bobShares);

        vm.prank(admin);
        vault.scheduleFeePolicy(_zeroFeePolicy(), epoch);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));
        vm.prank(operator);
        vault.finalizeEpoch(epoch, totalAum);

        uint256 pricingAum = totalAum - vault.netRequestedDepositAssets(epoch);
        uint256 sharesAtSettle = managerShares + bobShares;
        uint256 expectedNavPerShare = (pricingAum * 1e18) / sharesAtSettle;
        uint256 expectedAliceShares = (aliceDeposit * 1e18) / expectedNavPerShare;
        uint256 expectedBobAssets = (bobShares * expectedNavPerShare) / 1e18;

        vm.prank(operator);
        vault.settleDeposits(epoch, 10);
        vm.prank(operator);
        vault.settleRedeems(epoch, 10);

        (,, ReqStatus depositStatus) = vault.depositRequests(epoch, depositIndex);
        (,, ReqStatus redeemStatus) = vault.redeemRequests(epoch, redeemIndex);
        assertEq(uint8(depositStatus), uint8(ReqStatus.Settled));
        assertEq(uint8(redeemStatus), uint8(ReqStatus.Settled));
        assertEq(vault.balanceOf(alice), expectedAliceShares);
        assertEq(vault.claimableAssets(bob), expectedBobAssets);

        vm.prank(bob);
        uint256 claimed = vault.claim(bob);
        assertEq(claimed, expectedBobAssets);
        assertEq(vault.claimableAssets(bob), 0);
        assertEq(usdc.balanceOf(bob), expectedBobAssets);
    }

    /// @notice 延迟封账下，下一天请求不应污染前一天结算口径
    function test_flow_delayed_finalize_keeps_epoch_isolation() public {
        deal(address(vault), manager, 100e18, true);

        vm.prank(address(this));
        usdc.transfer(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 100e6);
        (uint256 epoch2, uint256 aliceIndex) = vault.requestDeposit(100e6, address(0));
        vm.stopPrank();

        vm.warp(block.timestamp + SECONDS_PER_EPOCH + 1);
        vm.prank(address(this));
        usdc.transfer(bob, 50e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 50e6);
        (uint256 epoch3, uint256 bobIndex) = vault.requestDeposit(50e6, address(0));
        vm.stopPrank();
        assertEq(epoch3, epoch2 + 1);

        vm.prank(admin);
        vault.scheduleFeePolicy(_zeroFeePolicy(), epoch2);
        vm.prank(admin);
        vault.scheduleFeePolicy(_zeroFeePolicy(), epoch3);

        // 延迟到下一天再回头封 epoch2
        vm.warp(block.timestamp + SECONDS_PER_EPOCH);
        vm.prank(operator);
        vault.finalizeEpoch(epoch2, 700e6);

        {
            uint256 epoch2PricingAum = 700e6 - vault.netRequestedDepositAssets(epoch2);
            uint256 epoch2Nav = (epoch2PricingAum * 1e18) / 100e18;
            uint256 expectedAliceShares = (100e6 * 1e18) / epoch2Nav;

            vm.prank(operator);
            vault.settleDeposits(epoch2, 10);

            (,, ReqStatus aliceStatus) = vault.depositRequests(epoch2, aliceIndex);
            (,, ReqStatus bobStatusBefore) = vault.depositRequests(epoch3, bobIndex);
            assertEq(uint8(aliceStatus), uint8(ReqStatus.Settled));
            assertEq(uint8(bobStatusBefore), uint8(ReqStatus.Pending));
            assertEq(vault.balanceOf(alice), expectedAliceShares);
        }

        // 再封 epoch3，验证 bob 的结算独立发生在自己的 epoch
        {
            uint256 sharesAtEpoch3 = vault.totalSupply();
            vm.prank(operator);
            vault.finalizeEpoch(epoch3, 800e6);

            uint256 epoch3PricingAum = 800e6 - vault.netRequestedDepositAssets(epoch3);
            uint256 epoch3Nav = (epoch3PricingAum * 1e18) / sharesAtEpoch3;
            uint256 expectedBobShares = (50e6 * 1e18) / epoch3Nav;

            vm.prank(operator);
            vault.settleDeposits(epoch3, 10);

            (,, ReqStatus bobStatusAfter) = vault.depositRequests(epoch3, bobIndex);
            assertEq(uint8(bobStatusAfter), uint8(ReqStatus.Settled));
            assertEq(vault.balanceOf(bob), expectedBobShares);
        }
    }

    /// @notice AUM 变化应反映到连续 epoch 的 NAV 变化
    function test_flow_nav_changes_with_aum_growth() public {
        uint256 managerShares = 100e18;
        deal(address(vault), manager, managerShares, true);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));
        uint256 epoch1 = vault.currentEpoch() - 1;
        vm.prank(operator);
        vault.finalizeEpoch(epoch1, 500e6);

        vm.warp(block.timestamp + SECONDS_PER_EPOCH);
        uint256 epoch2 = vault.currentEpoch() - 1;
        vm.prank(operator);
        vault.finalizeEpoch(epoch2, 700e6);

        (,, uint256 nav1,) = vault.snapshots(epoch1);
        (,, uint256 nav2,) = vault.snapshots(epoch2);
        assertGt(nav2, nav1);
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
}
