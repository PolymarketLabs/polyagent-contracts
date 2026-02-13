// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IVaultAdmin} from "./interfaces/IVaultAdmin.sol";

abstract contract VaultAdmin is AccessControlUpgradeable, IVaultAdmin {
    // ===== 管理员事件 =====
    event AdminUpdated(address indexed previousAdmin, address indexed newAdmin);
    event OperatorUpdated(address indexed previousOperator, address indexed newOperator);
    event ExecutorUpdated(address indexed previousExecutor, address indexed newExecutor);
    event DepositPauseStatusUpdated(address indexed admin, bool paused);
    event RedeemPauseStatusUpdated(address indexed admin, bool paused);

    // ===== 管理员错误 =====
    error ZeroAddress();
    error DepositPaused();
    error DepositNotPaused();
    error RedeemPaused();
    error RedeemNotPaused();

    // ===== 角色常量 =====
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // ===== 角色地址 =====
    address public admin; // 默认管理员地址
    address public operator; // 运营角色地址
    address public executor; // 执行钱包

    // ===== 运行状态 =====
    bool public depositPaused; // 申购暂停开关
    bool public redeemPaused; // 赎回暂停开关

    // ===== 升级预留 =====
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256[50] private __gap;

    // ===== 管理员操作 =====

    function setAdmin(address newAdmin) public virtual override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAdmin == address(0)) {
            revert ZeroAddress();
        }

        address previousAdmin = admin;
        if (newAdmin == previousAdmin) {
            return;
        }

        _grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        _revokeRole(DEFAULT_ADMIN_ROLE, previousAdmin);
        admin = newAdmin;

        emit AdminUpdated(previousAdmin, newAdmin);
    }

    function setOperator(address newOperator) public virtual override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newOperator == address(0)) {
            revert ZeroAddress();
        }

        address previousOperator = operator;
        if (newOperator == previousOperator) {
            return;
        }

        _grantRole(OPERATOR_ROLE, newOperator);
        _revokeRole(OPERATOR_ROLE, previousOperator);
        operator = newOperator;

        emit OperatorUpdated(previousOperator, newOperator);
    }

    function setExecutor(address newExecutor) public virtual override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newExecutor == address(0)) {
            revert ZeroAddress();
        }

        address previousExecutor = executor;
        if (newExecutor == previousExecutor) {
            return;
        }

        executor = newExecutor;

        emit ExecutorUpdated(previousExecutor, newExecutor);
    }

    function pauseDeposit() public virtual override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (depositPaused) {
            revert DepositPaused();
        }
        depositPaused = true;
        emit DepositPauseStatusUpdated(msg.sender, true);
    }

    function unpauseDeposit() public virtual override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!depositPaused) {
            revert DepositNotPaused();
        }
        depositPaused = false;
        emit DepositPauseStatusUpdated(msg.sender, false);
    }

    function pauseRedeem() public virtual override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (redeemPaused) {
            revert RedeemPaused();
        }
        redeemPaused = true;
        emit RedeemPauseStatusUpdated(msg.sender, true);
    }

    function unpauseRedeem() public virtual override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!redeemPaused) {
            revert RedeemNotPaused();
        }
        redeemPaused = false;
        emit RedeemPauseStatusUpdated(msg.sender, false);
    }
}
