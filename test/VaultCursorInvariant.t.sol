// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Vault} from "../src/Vault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {FeePolicy, FeeRateConfig, SplitConfig, FeeRecipientConfig} from "../src/vault/VaultTypes.sol";
import {USDC} from "./mocks/USDC.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Handler exposes only settlement operations for invariant fuzzing.
contract VaultSettlementCursorHandler is Test {
    Vault public immutable vault;
    uint256 public immutable epoch;
    address public immutable operator;
    uint256 public immutable depositCount;
    uint256 public immutable redeemCount;

    uint256 public lastDepositCursor;
    uint256 public lastRedeemCursor;

    constructor(Vault _vault, uint256 _epoch, address _operator, uint256 _depositCount, uint256 _redeemCount) {
        vault = _vault;
        epoch = _epoch;
        operator = _operator;
        depositCount = _depositCount;
        redeemCount = _redeemCount;
    }

    function settleDeposits(uint256 rawMaxCount) external {
        _settleDeposits(rawMaxCount);
    }

    function settleRedeems(uint256 rawMaxCount) external {
        _settleRedeems(rawMaxCount);
    }

    function settleDepositsAndRedeems(uint256 rawDepositMaxCount, uint256 rawRedeemMaxCount) external {
        _settleDeposits(rawDepositMaxCount);
        _settleRedeems(rawRedeemMaxCount);
    }

    function settleRedeemsFirst(uint256 rawRedeemMaxCount, uint256 rawDepositMaxCount) external {
        _settleRedeems(rawRedeemMaxCount);
        _settleDeposits(rawDepositMaxCount);
    }

    function settleDepositsOnly(uint256 rawMaxCount) external {
        _settleDeposits(rawMaxCount);
    }

    function settleRedeemsOnly(uint256 rawMaxCount) external {
        _settleRedeems(rawMaxCount);
    }

    function _settleDeposits(uint256 rawMaxCount) internal {
        // Once done is true, calling settle again would revert by design.
        (,, bool depositsDone,) = vault.cursors(epoch);
        if (depositsDone) {
            return;
        }

        uint256 maxCount = bound(rawMaxCount, 1, 8);
        vm.prank(operator);
        vault.settleDeposits(epoch, maxCount);

        (uint256 nextDeposit,, bool doneAfter,) = vault.cursors(epoch);
        assertGe(nextDeposit, lastDepositCursor);
        assertLe(nextDeposit, depositCount);
        lastDepositCursor = nextDeposit;
        if (doneAfter) {
            assertEq(nextDeposit, depositCount);
        }
    }

    function _settleRedeems(uint256 rawMaxCount) internal {
        // Once done is true, calling settle again would revert by design.
        (,,, bool redeemsDone) = vault.cursors(epoch);
        if (redeemsDone) {
            return;
        }

        uint256 maxCount = bound(rawMaxCount, 1, 8);
        vm.prank(operator);
        vault.settleRedeems(epoch, maxCount);

        (, uint256 nextRedeem,, bool doneAfter) = vault.cursors(epoch);
        assertGe(nextRedeem, lastRedeemCursor);
        assertLe(nextRedeem, redeemCount);
        lastRedeemCursor = nextRedeem;
        if (doneAfter) {
            assertEq(nextRedeem, redeemCount);
        }
    }
}

/// @notice Invariant: settlement cursors are monotonic, bounded, and consistent with done flags.
contract VaultCursorInvariantTest is StdInvariant, Test {
    uint256 public constant INITIAL_TIMESTAMP = 1767225600; // 2026-01-01 00:00:00 UTC
    uint256 public constant SECONDS_PER_EPOCH = 86400;

    USDC public usdc;
    VaultFactory public factory;
    Vault public vault;
    VaultSettlementCursorHandler public handler;

    address beaconOwner = makeAddr("beaconOwner");
    address owner = makeAddr("owner");
    address manager = makeAddr("manager");
    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address executor = makeAddr("executor");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 public settledEpoch;
    uint256 public constant DEPOSIT_COUNT = 12;
    uint256 public constant REDEEM_COUNT = 9;

    function setUp() public {
        // Build a deterministic finalized epoch with both deposit/redeem queues populated.
        vm.warp(INITIAL_TIMESTAMP);
        usdc = new USDC();

        factory = _deployFactory(owner);
        vault = Vault(_createFund(factory, address(usdc), manager, admin, operator, executor, SECONDS_PER_EPOCH));

        uint256 managerShares = 1_000e18;
        deal(address(vault), manager, managerShares, true);
        deal(address(vault), bob, REDEEM_COUNT * 1e18, true);

        uint256 totalDepositAmount = DEPOSIT_COUNT * 10e6;
        vm.prank(address(this));
        usdc.transfer(alice, totalDepositAmount);

        vm.startPrank(alice);
        usdc.approve(address(vault), totalDepositAmount);
        for (uint256 i = 0; i < DEPOSIT_COUNT; i++) {
            vault.requestDeposit(10e6, address(0));
        }
        vm.stopPrank();

        vm.startPrank(bob);
        for (uint256 i = 0; i < REDEEM_COUNT; i++) {
            vault.requestRedeem(1e18);
        }
        vm.stopPrank();

        settledEpoch = vault.currentEpoch();
        vm.prank(admin);
        vault.scheduleFeePolicy(_zeroFeePolicy(), settledEpoch);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH));
        vm.prank(operator);
        vault.finalizeEpoch(settledEpoch, 5_000_000e6);

        // Restrict invariant engine to handler selectors to avoid unrelated calls noise.
        handler = new VaultSettlementCursorHandler(vault, settledEpoch, operator, DEPOSIT_COUNT, REDEEM_COUNT);
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = VaultSettlementCursorHandler.settleDepositsAndRedeems.selector;
        selectors[1] = VaultSettlementCursorHandler.settleRedeemsFirst.selector;
        selectors[2] = VaultSettlementCursorHandler.settleDepositsOnly.selector;
        selectors[3] = VaultSettlementCursorHandler.settleRedeemsOnly.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_settlementCursor_monotonicAndBounded() public view {
        (uint256 nextDeposit, uint256 nextRedeem, bool depositsDone, bool redeemsDone) = vault.cursors(settledEpoch);

        // Cursors should never exceed queue sizes and should never move backward.
        assertLe(nextDeposit, DEPOSIT_COUNT);
        assertLe(nextRedeem, REDEEM_COUNT);
        assertGe(nextDeposit, handler.lastDepositCursor());
        assertGe(nextRedeem, handler.lastRedeemCursor());

        if (depositsDone) {
            assertEq(nextDeposit, DEPOSIT_COUNT);
        }
        if (redeemsDone) {
            assertEq(nextRedeem, REDEEM_COUNT);
        }
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
