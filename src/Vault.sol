// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IVault} from "./interfaces/IVault.sol";
import {DepositRequest, RedeemRequest, EpochSnapshot, SettlementCursor} from "./vault/VaultTypes.sol";
import "./vault/VaultEvents.sol";
import "./vault/VaultErrors.sol";

contract Vault is ERC20Upgradeable, AccessControlUpgradeable, IVault {
    // 角色配置
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // 基础配置
    address public baseAsset; // 基础资产（默认 USDC）
    uint256 public secondsPerEpoch; // 默认 86400
    uint256 public epoch0; // epoch 起点（部署时 floor(ts/86400)）
    uint256 public minDepositAmount; // 最小申购金额
    uint256 public minRedeemShares; // 最小赎回份额

    // 角色地址
    address public admin;
    address public operator;
    address public executor; // 执行钱包

    // 状态
    bool public depositPaused;
    bool public redeemPaused;

    /// @notice 可领取资产 investor => amount
    mapping(address => uint256) public claimableAssets;

    /// @notice epoch => request
    mapping(uint256 => DepositRequest[]) public depositRequests;
    mapping(uint256 => RedeemRequest[]) public redeemRequests;

    /// @notice epoch => snapshot
    mapping(uint256 => EpochSnapshot) public snapshots;

    /// @notice epoch => cursor
    mapping(uint256 => SettlementCursor) public cursors;

    /// @notice 预留升级槽位
    uint256[100] private _gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory tokenName,
        string memory tokenSymbol,
        address _baseAsset,
        address _admin,
        address _operator,
        address _executor,
        uint256 _secondsPerEpoch
    ) external override initializer {
        if (address(0) == _baseAsset) revert ZeroAddress();
        if (address(0) == _admin) revert ZeroAddress();
        if (address(0) == _operator) revert ZeroAddress();
        if (address(0) == _executor) revert ZeroAddress();
        if (_secondsPerEpoch == 0) revert InvalidSecondsPerEpoch();

        __AccessControl_init();
        __ERC20_init(tokenName, tokenSymbol);

        baseAsset = _baseAsset;

        admin = _admin;
        operator = _operator;
        executor = _executor;

        secondsPerEpoch = _secondsPerEpoch;
        epoch0 = block.timestamp / secondsPerEpoch;
        minDepositAmount = 1;
        minRedeemShares = 1;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _operator);
    }

    // === 用户操作 ===

    /// @notice 提交申购请求（仅收钱，不铸造份额）
    /// @return epoch 请求归属的结算日（UTC day）
    /// @return index 该 epoch 内的请求序号（与 epoch 组合唯一标识一笔请求）
    function requestDeposit(uint256 amount) external override returns (uint256 epoch, uint256 index) {}

    /// @notice 提交赎回请求（仅锁份额，不销毁）
    function requestRedeem(uint256 shares) external override returns (uint256 epoch, uint256 index) {}

    /// @notice 撤销未结算的申购请求（退回资金）
    function cancelDeposit(uint256 epoch, uint256 index) external override {}

    /// @notice 撤销未结算的赎回请求（解锁份额）
    function cancelRedeem(uint256 epoch, uint256 index) external override {}

    /// @notice 领取已结算赎回产生的可领取余额
    function claim(address to) external override returns (uint256 amount) {}

    // === 运营操作 ===

    /// @notice 封账，关闭某个 epoch，输入 totalAum，计算 navPerShare
    /// @param epoch 要结算的结算日（必须 < currentEpoch）
    /// @param totalAum 该 epoch 的资产总值（baseAsset 计价）
    function finalizeEpoch(uint256 epoch, uint256 totalAum) external override onlyRole(OPERATOR_ROLE) {}

    /// @notice 分批处理申购请求，防止Dos
    /// @param epoch 要结算的结算日（必须 < currentEpoch）
    /// @param maxCount 本次最多结算多少条
    function settleDeposits(uint256 epoch, uint256 maxCount) external override onlyRole(OPERATOR_ROLE) {}

    /// @notice 分批处理赎回请求，防止Dos
    /// @param epoch 要结算的结算日（必须 < currentEpoch）
    /// @param maxCount 本次最多结算多少条
    function settleRedeems(uint256 epoch, uint256 maxCount) external override onlyRole(OPERATOR_ROLE) {}

    /// @notice 划转资金到执行钱包
    /// @param amount 划转金额
    function transferToExecutor(uint256 amount) external override onlyRole(OPERATOR_ROLE) {}

    // === 管理员操作 ===

    /// @notice 暂停申购功能
    function pauseDeposit() external override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /// @notice 恢复申购功能
    function unpauseDeposit() external override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /// @notice 暂停赎回功能
    function pauseRedeem() external override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /// @notice 恢复赎回功能
    function unpauseRedeem() external override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // === 只读 ===

    /// @notice 当前 epoch（UTC day = floor(block.timestamp/86400)）
    function currentEpoch() external view override returns (uint256) {
        return block.timestamp / secondsPerEpoch;
    }

    /// @notice 初始化版本号（initializer=1, reinitializer(2)=2）
    function initializedVersion() external view override returns (uint64) {
        return _getInitializedVersion();
    }

    function depositRequestCount(uint256 epoch) external view override returns (uint256) {}

    function redeemRequestCount(uint256 epoch) external view override returns (uint256) {}
}
