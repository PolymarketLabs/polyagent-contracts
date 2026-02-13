// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../src/Vault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {ReqStatus, FeePolicy, FeeRateConfig, SplitConfig, FeeRecipientConfig} from "../src/vault/VaultTypes.sol";
import {USDC} from "./mocks/USDC.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Fuzz tests for fee split math and reserve fallback behavior.
contract VaultFuzzTest is Test {
    uint256 public constant INITIAL_TIMESTAMP = 1767225600; // 2026-01-01 00:00:00 UTC
    uint256 public constant SECONDS_PER_EPOCH = 86400;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

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
    }

    function testFuzz_settleDeposits_feeSplit_noReferrer_routesToReserve(
        uint96 rawAmount,
        uint16 rawEntryFeeBps,
        uint16 rawPlatformBps,
        uint16 rawReferrerBps,
        uint16 rawManagerBps
    ) public {
        // Bound fuzz inputs to realistic ranges and valid bps.
        uint256 amount = bound(uint256(rawAmount), 1e6, 500_000e6);
        uint16 entryFeeBps = uint16(bound(uint256(rawEntryFeeBps), 0, BPS_DENOMINATOR));
        SplitConfig memory split = _boundedSplit(rawPlatformBps, rawReferrerBps, rawManagerBps);

        uint256 managerShares = 200e18;
        deal(address(vault), manager, managerShares, true);

        vm.prank(address(this));
        usdc.transfer(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        (uint256 epoch, uint256 index) = vault.requestDeposit(amount, address(0));
        vm.stopPrank();

        vm.prank(admin);
        vault.scheduleFeePolicy(_entryFeePolicy(entryFeeBps, split), epoch);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));
        vm.prank(operator);
        vault.finalizeEpoch(epoch, amount + 500e6);

        vm.prank(operator);
        vault.settleDeposits(epoch, 1);

        uint256 fee = (amount * entryFeeBps) / BPS_DENOMINATOR;
        uint256 platformAmount = (fee * split.platformBps) / BPS_DENOMINATOR;
        uint256 referrerAmount = (fee * split.referrerBps) / BPS_DENOMINATOR;
        uint256 managerAmount = (fee * split.managerBps) / BPS_DENOMINATOR;
        uint256 remainderAmount = fee - platformAmount - referrerAmount - managerAmount;

        // No referrer is bound for alice, so referrer share + remainder must go to reserve.
        assertEq(vault.feeClaimableOf(admin), platformAmount);
        assertEq(vault.feeClaimableOf(manager), managerAmount);
        assertEq(vault.feeClaimableOf(executor), referrerAmount + remainderAmount);
        assertEq(vault.feeClaimableOf(bob), 0);

        (,, ReqStatus status) = vault.depositRequests(epoch, index);
        assertEq(uint8(status), uint8(ReqStatus.Settled));
    }

    function testFuzz_settleRedeems_feeSplit_noReferrer_routesToReserve(
        uint96 rawTotalAum,
        uint96 rawShares,
        uint16 rawExitFeeBps,
        uint16 rawPlatformBps,
        uint16 rawReferrerBps,
        uint16 rawManagerBps
    ) public {
        // Keep NAV math stable and avoid degenerate inputs.
        uint256 redeemShares = bound(uint256(rawShares), 1e18, 80e18);
        uint256 totalAum = bound(uint256(rawTotalAum), 500e6, 2_000_000e6);
        uint16 exitFeeBps = uint16(bound(uint256(rawExitFeeBps), 0, BPS_DENOMINATOR));
        SplitConfig memory split = _boundedSplit(rawPlatformBps, rawReferrerBps, rawManagerBps);

        uint256 managerShares = 300e18;
        deal(address(vault), manager, managerShares, true);
        deal(address(vault), alice, redeemShares, true);

        vm.prank(alice);
        (uint256 epoch, uint256 index) = vault.requestRedeem(redeemShares);

        vm.prank(admin);
        vault.scheduleFeePolicy(_exitFeePolicy(exitFeeBps, split), epoch);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));
        vm.prank(operator);
        vault.finalizeEpoch(epoch, totalAum);

        vm.prank(operator);
        vault.settleRedeems(epoch, 1);

        uint256 navPerShare = (totalAum * 1e18) / (managerShares + redeemShares);
        uint256 grossAssets = (redeemShares * navPerShare) / 1e18;
        uint256 fee = (grossAssets * exitFeeBps) / BPS_DENOMINATOR;
        uint256 platformAmount = (fee * split.platformBps) / BPS_DENOMINATOR;
        uint256 referrerAmount = (fee * split.referrerBps) / BPS_DENOMINATOR;
        uint256 managerAmount = (fee * split.managerBps) / BPS_DENOMINATOR;
        uint256 remainderAmount = fee - platformAmount - referrerAmount - managerAmount;

        assertEq(vault.feeClaimableOf(admin), platformAmount);
        assertEq(vault.feeClaimableOf(manager), managerAmount);
        assertEq(vault.feeClaimableOf(executor), referrerAmount + remainderAmount);
        assertEq(vault.feeClaimableOf(bob), 0);
        assertEq(vault.claimableAssets(alice), grossAssets - fee);

        (,, ReqStatus status) = vault.redeemRequests(epoch, index);
        assertEq(uint8(status), uint8(ReqStatus.Settled));
    }

    function _boundedSplit(uint16 rawPlatformBps, uint16 rawReferrerBps, uint16 rawManagerBps)
        internal
        pure
        returns (SplitConfig memory split)
    {
        // Normalize split so sum never exceeds 10000 bps.
        uint256 platform = uint256(rawPlatformBps) % (BPS_DENOMINATOR + 1);
        uint256 referrer = uint256(rawReferrerBps) % (BPS_DENOMINATOR + 1);
        uint256 managerSplit = uint256(rawManagerBps) % (BPS_DENOMINATOR + 1);
        uint256 sum = platform + referrer + managerSplit;
        if (sum > BPS_DENOMINATOR) {
            platform = (platform * BPS_DENOMINATOR) / sum;
            referrer = (referrer * BPS_DENOMINATOR) / sum;
            managerSplit = (managerSplit * BPS_DENOMINATOR) / sum;
        }

        split = SplitConfig({
            platformBps: uint16(platform), referrerBps: uint16(referrer), managerBps: uint16(managerSplit)
        });
    }

    function _entryFeePolicy(uint16 entryFeeBps, SplitConfig memory entrySplit)
        internal
        view
        returns (FeePolicy memory policy)
    {
        policy = FeePolicy({
            rates: FeeRateConfig({entryFeeBps: entryFeeBps, exitFeeBps: 0, mgmtFeeAnnualBps: 0, performanceFeeBps: 0}),
            entrySplit: entrySplit,
            exitSplit: SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 0}),
            mgmtSplit: SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 0}),
            performanceSplit: SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 0}),
            recipients: FeeRecipientConfig({platform: admin, manager: manager, reserve: executor})
        });
    }

    function _exitFeePolicy(uint16 exitFeeBps, SplitConfig memory exitSplit)
        internal
        view
        returns (FeePolicy memory policy)
    {
        policy = FeePolicy({
            rates: FeeRateConfig({entryFeeBps: 0, exitFeeBps: exitFeeBps, mgmtFeeAnnualBps: 0, performanceFeeBps: 0}),
            entrySplit: SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 0}),
            exitSplit: exitSplit,
            mgmtSplit: SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 0}),
            performanceSplit: SplitConfig({platformBps: 0, referrerBps: 0, managerBps: 0}),
            recipients: FeeRecipientConfig({platform: admin, manager: manager, reserve: executor})
        });
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
