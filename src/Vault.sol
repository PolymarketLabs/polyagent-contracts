// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVault} from "./interfaces/IVault.sol";
import {
    DepositRequest,
    RedeemRequest,
    ReqStatus,
    EpochSnapshot,
    SettlementCursor,
    FeePolicy,
    FeePolicyCheckpoint
} from "./vault/VaultTypes.sol";
import {VaultEvents} from "./vault/VaultEvents.sol";
import {VaultErrors} from "./vault/VaultErrors.sol";

contract Vault is ERC20Upgradeable, AccessControlUpgradeable, IVault, VaultEvents, VaultErrors {
    using SafeERC20 for IERC20;

    // ===== 角色常量 =====
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // ===== 基础配置 =====
    address public baseAsset; // 基础资产地址（如 USDC）
    uint256 public secondsPerEpoch; // 结算周期长度（秒）
    uint256 public epoch0; // 初始化时刻对应的 epoch 起点
    uint256 public minDepositAmount; // 最小申购金额
    uint256 public minRedeemShares; // 最小赎回份额

    // ===== 角色地址 =====
    address public admin; // 默认管理员地址
    address public operator; // 运营角色地址
    address public executor; // 执行钱包

    // ===== 运行状态 =====
    bool public depositPaused; // 申购暂停开关
    bool public redeemPaused; // 赎回暂停开关

    // ===== 用户请求与结算状态 =====
    mapping(address => uint256) public claimableAssets; // investor => 可领取基础资产

    mapping(uint256 => DepositRequest[]) public depositRequests; // epoch => 申购请求列表
    mapping(uint256 => RedeemRequest[]) public redeemRequests; // epoch => 赎回请求列表

    mapping(uint256 => EpochSnapshot) public snapshots; // epoch => 封账快照

    mapping(uint256 => SettlementCursor) public cursors; // epoch => 批处理游标

    // ===== 费用策略状态 =====
    uint256 public highWaterMarkNav; // 业绩报酬高水位净值（预留）
    FeePolicyCheckpoint[] private feePolicyCheckpoints; // 按生效 epoch 递增存储的策略检查点
    mapping(address => address) public referrers; // 投资者 -> 推荐人（首绑生效）
    mapping(address => uint256) public feeClaimable; // 收款方可领取费用余额

    // ===== 升级预留 =====
    uint256[96] private _gap;

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

    // ===== 用户操作 =====

    function requestDeposit(uint256 amount, address referrer) external override returns (uint256 epoch, uint256 index) {
        // 暂停期间禁止提交申购请求
        if (depositPaused) {
            revert DepositPaused();
        }
        // 仅接受不低于最小申购门槛的金额
        if (amount < minDepositAmount) {
            revert AmountTooSmall();
        }

        // 推荐人仅在未绑定时写入
        _bindReferrerIfUnbound(msg.sender, referrer);

        // 先收取基础资产，再记录请求，避免出现“有请求无资产”
        IERC20(baseAsset).safeTransferFrom(msg.sender, address(this), amount);

        epoch = _currentEpoch();
        index = depositRequests[epoch].length;

        // 请求入队，后续由结算流程统一处理
        depositRequests[epoch].push(
            DepositRequest({investor: msg.sender, amount: amount, status: ReqStatus.Pending, epoch: epoch})
        );

        emit DepositRequested(epoch, index, msg.sender, amount);
    }

    function requestRedeem(uint256 shares) external override returns (uint256 epoch, uint256 index) {
        // 暂停期间禁止提交赎回请求
        if (redeemPaused) {
            revert RedeemPaused();
        }
        // 仅接受不低于最小赎回门槛的份额
        if (shares < minRedeemShares) {
            revert AmountTooSmall();
        }

        // 先锁定份额，再记录请求，避免出现“有请求无份额”
        _transfer(msg.sender, address(this), shares);

        epoch = _currentEpoch();
        index = redeemRequests[epoch].length;

        // 请求入队，后续由结算流程统一处理
        redeemRequests[epoch].push(
            RedeemRequest({investor: msg.sender, shares: shares, status: ReqStatus.Pending, epoch: epoch})
        );

        emit RedeemRequested(epoch, index, msg.sender, shares);
    }

    function cancelDeposit(uint256 epoch, uint256 index) external override {}

    function cancelRedeem(uint256 epoch, uint256 index) external override {}

    function claim(address to) external override returns (uint256 amount) {}

    // ===== 运营操作 =====

    function finalizeEpoch(uint256 epoch, uint256 totalAum) external override onlyRole(OPERATOR_ROLE) {}

    function settleDeposits(uint256 epoch, uint256 maxCount) external override onlyRole(OPERATOR_ROLE) {}

    function settleRedeems(uint256 epoch, uint256 maxCount) external override onlyRole(OPERATOR_ROLE) {}

    function transferToExecutor(uint256 amount) external override onlyRole(OPERATOR_ROLE) {}

    // ===== 管理员操作 =====

    function pauseDeposit() external override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function unpauseDeposit() external override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function pauseRedeem() external override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function unpauseRedeem() external override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function scheduleFeePolicy(FeePolicy calldata policy, uint256 effectiveEpoch)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        uint256 checkpointsLen = feePolicyCheckpoints.length;
        if (checkpointsLen > 0 && effectiveEpoch <= feePolicyCheckpoints[checkpointsLen - 1].effectiveEpoch) {
            revert InvalidEffectiveEpoch();
        }

        feePolicyCheckpoints.push(FeePolicyCheckpoint({effectiveEpoch: effectiveEpoch, policy: policy}));

        emit FeePolicyScheduled(checkpointsLen, effectiveEpoch);
    }

    function bindReferrer(address referrer) external override {
        _bindReferrerIfUnbound(msg.sender, referrer);
    }

    function claimFee(address to) external override returns (uint256 amount) {}

    // ===== 只读查询 =====

    function currentEpoch() external view override returns (uint256) {
        return _currentEpoch();
    }

    function initializedVersion() external view override returns (uint64) {
        return _getInitializedVersion();
    }

    function depositRequestCount(uint256 epoch) external view override returns (uint256) {}

    function redeemRequestCount(uint256 epoch) external view override returns (uint256) {}

    function referrerOf(address investor) external view override returns (address) {
        return referrers[investor];
    }

    function feeClaimableOf(address recipient) external view override returns (uint256) {
        return feeClaimable[recipient];
    }

    function currentFeePolicy() external view override returns (FeePolicy memory) {
        uint256 epoch = _currentEpoch();
        uint256 len = feePolicyCheckpoints.length;

        for (uint256 i = len; i > 0; i--) {
            FeePolicyCheckpoint storage checkpoint = feePolicyCheckpoints[i - 1];
            if (checkpoint.effectiveEpoch <= epoch) {
                return checkpoint.policy;
            }
        }

        revert FeePolicyNotFound();
    }

    function previewEntryFee(uint256 amount) external view override returns (uint256 fee, uint256 netAmount) {
        fee = 0;
        netAmount = amount;
    }

    function previewExitFee(uint256 amount) external view override returns (uint256 fee, uint256 netAmount) {
        fee = 0;
        netAmount = amount;
    }

    /// @dev 仅在首次绑定时写入推荐人；禁止自荐与互荐（A<->B）
    function _bindReferrerIfUnbound(address investor, address referrer) internal {
        if (referrer == address(0)) {
            return;
        }
        if (investor == referrer) {
            revert SelfReferral();
        }
        if (referrers[referrer] == investor) {
            revert CircularReferral();
        }
        if (referrers[investor] != address(0)) {
            return;
        }
        referrers[investor] = referrer;
        emit ReferrerBound(investor, referrer);
    }

    function _currentEpoch() internal view returns (uint256) {
        return block.timestamp / secondsPerEpoch;
    }
}
