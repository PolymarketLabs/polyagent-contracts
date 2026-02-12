// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../src/Vault.sol";
import {VaultErrors} from "../src/vault/VaultErrors.sol";
import {ReqStatus} from "../src/vault/VaultTypes.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {USDC} from "./mocks/USDC.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {VaultFactory} from "../src/VaultFactory.sol";

contract VaultTest is Test {
    uint256 public constant INITIAL_TIMESTAMP = 1767225600; // 2026-01-01 00:00:00 UTC
    uint256 public constant SECONDS_PER_EPOCH = 86400;
    uint256 internal constant SNAPSHOTS_MAPPING_SLOT = 11; // Vault.snapshots 的映射槽位（需与 Vault 存储布局保持一致）

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

        (address investor, uint256 recordedAmount, ReqStatus status, uint256 recordedEpoch) =
            vault.depositRequests(epoch, index);
        assertEq(investor, alice);
        assertEq(recordedAmount, amount);
        assertEq(uint8(status), uint8(ReqStatus.Pending));
        assertEq(recordedEpoch, epoch);
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

        (address investor, uint256 recordedShares, ReqStatus status, uint256 recordedEpoch) =
            vault.redeemRequests(epoch, index);
        assertEq(investor, alice);
        assertEq(recordedShares, shares);
        assertEq(uint8(status), uint8(ReqStatus.Pending));
        assertEq(recordedEpoch, epoch);
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

        (address investor, uint256 recordedAmount, ReqStatus status, uint256 recordedEpoch) =
            vault.depositRequests(epoch, index);
        assertEq(investor, alice);
        assertEq(recordedAmount, amount);
        assertEq(uint8(status), uint8(ReqStatus.Canceled));
        assertEq(recordedEpoch, epoch);
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

    // TODO(vault): 待业务函数实现后补充以下测试（函数名预留 + 中文说明）
    // function test_requestDeposit_reverts_whenDepositPaused() public {} // 申购暂停时应回滚
    // function test_requestRedeem_reverts_whenRedeemPaused() public {} // 赎回暂停时应回滚
    // function test_cancelRedeem_reverts_whenNotRequestOwner() public {} // 非请求所有者撤销赎回应回滚
    // function test_cancelRedeem_reverts_whenEpochAlreadyFinalized() public {} // 已封账 epoch 的赎回撤销应回滚
    // function test_cancelRedeem_unlocksSharesAndMarksCanceled() public {} // 撤销赎回后应解锁份额并标记 Canceled
    // function test_finalizeEpoch_reverts_whenCalledByNonOperator() public {} // 非 operator 封账应回滚
    // function test_finalizeEpoch_reverts_forCurrentOrFutureEpoch() public {} // 当前或未来 epoch 封账应回滚
    // function test_finalizeEpoch_reverts_whenCalledTwiceForSameEpoch() public {} // 同一 epoch 二次封账应回滚
    // function test_finalizeEpoch_storesSnapshotAndEmitsEvent() public {} // 封账应写入快照并触发事件
    // function test_settleDeposits_processesBatchAndUpdatesCursor() public {} // 申购批结算应推进游标并更新状态
    // function test_settleRedeems_processesBatchAndUpdatesCursor() public {} // 赎回批结算应推进游标并更新状态
    // function test_claim_transfersClaimableAssetsAndEmitsClaimed() public {} // claim 应转出可领取资产并触发 Claimed
    // function test_transferToExecutor_reverts_whenCalledByNonOperator() public {} // 非 operator 划转执行钱包应回滚
    // function test_transferToExecutor_transfersBaseAssetToExecutor() public {} // operator 划转执行钱包应成功转账
    // function test_pauseDeposit_onlyAdminCanToggle() public {} // 仅 admin 可切换申购暂停状态
    // function test_pauseRedeem_onlyAdminCanToggle() public {} // 仅 admin 可切换赎回暂停状态
    // function test_depositRequestCount_returnsPerEpochLength() public {} // depositRequestCount 应返回对应 epoch 请求数
    // function test_redeemRequestCount_returnsPerEpochLength() public {} // redeemRequestCount 应返回对应 epoch 请求数
}
