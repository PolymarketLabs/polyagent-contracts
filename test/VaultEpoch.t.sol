// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {VaultTestBase} from "./shared/VaultTestBase.sol";
import {VaultFactory} from "../src/VaultFactory.sol";

contract VaultEpochTest is VaultTestBase {
    uint256 public constant INITIAL_TIMESTAMP = 1767225600; // 2026-01-01 00:00:00 UTC
    uint256 public constant SECONDS_PER_EPOCH = 86400;
    uint256 public constant INITIAL_MIN_DEPOSIT_AMOUNT = 1;
    uint256 public constant INITIAL_MIN_REDEEM_SHARES = 1;

    function setUp() public {
        _setUpVaultFixture(INITIAL_TIMESTAMP, SECONDS_PER_EPOCH, INITIAL_MIN_DEPOSIT_AMOUNT, INITIAL_MIN_REDEEM_SHARES);
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

    /// @notice secondsPerEpoch 为 0 时应回滚
    function test_initialize_reverts_whenSecondsPerEpochIsZero() public {
        VaultFactory localFactory = _deployFactory(owner);
        vm.prank(owner);
        vm.expectRevert();
        localFactory.createFund(
            "Alpha Fund Share",
            "AFS",
            address(usdc),
            manager,
            admin,
            operator,
            executor,
            0,
            INITIAL_MIN_DEPOSIT_AMOUNT,
            INITIAL_MIN_REDEEM_SHARES
        );
    }

    /// @notice 时间前进后 currentEpoch 应按周期递增
    function test_currentEpoch_increases_whenTimeMovesForward() public {
        uint256 epoch = vault.currentEpoch();

        vm.warp(block.timestamp + SECONDS_PER_EPOCH);
        assertEq(vault.currentEpoch(), epoch + 1);

        vm.warp(block.timestamp + (2 * SECONDS_PER_EPOCH) + 123);
        assertEq(vault.currentEpoch(), epoch + 3);
    }
}
