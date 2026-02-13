// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
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

contract Vault is ERC20Upgradeable, AccessControlUpgradeable, ReentrancyGuard, IVault, VaultEvents, VaultErrors {
    using SafeERC20 for IERC20;
    uint256 private constant NAV_SCALE = 1e18; // 采用 1e18 精度记录 NAV，避免与份额 decimals 耦合

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
    
    mapping(uint256 => uint256) public netRequestedDepositAssets; // epoch => 净申购总资产
    mapping(uint256 => uint256) public netRequestedRedeemShares; // epoch => 净赎回总份额

    mapping(uint256 => EpochSnapshot) public snapshots; // epoch => 封账快照

    mapping(uint256 => SettlementCursor) public cursors; // epoch => 批处理游标

    // ===== 费用策略状态 =====
    uint256 public highWaterMarkNav; // 业绩报酬高水位净值（预留）
    FeePolicyCheckpoint[] private feePolicyCheckpoints; // 按生效 epoch 递增存储的策略检查点
    mapping(address => address) public referrers; // 投资者 -> 推荐人（首绑生效）
    mapping(address => uint256) public feeClaimable; // 收款方可领取费用余额

    // ===== 升级预留 =====
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

    // ===== 用户操作 =====

    function requestDeposit(uint256 amount, address referrer)
        external
        override
        nonReentrant
        returns (uint256 epoch, uint256 index)
    {
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

        epoch = _currentEpoch();
        index = depositRequests[epoch].length;

        // 按严格 CEI：先写入状态，再进行外部交互
        depositRequests[epoch].push(
            DepositRequest({investor: msg.sender, amount: amount, status: ReqStatus.Pending})
        );
        netRequestedDepositAssets[epoch] += amount;

        // 外部交互放在最后；若转账失败，整笔交易回滚，已写状态不会保留
        IERC20(baseAsset).safeTransferFrom(msg.sender, address(this), amount);

        emit DepositRequested(epoch, index, msg.sender, amount);
    }

    function requestRedeem(uint256 shares) external override nonReentrant returns (uint256 epoch, uint256 index) {
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
            RedeemRequest({investor: msg.sender, shares: shares, status: ReqStatus.Pending})
        );
        netRequestedRedeemShares[epoch] += shares;

        emit RedeemRequested(epoch, index, msg.sender, shares);
    }

    function cancelDeposit(uint256 epoch, uint256 index) external override nonReentrant {
        // 已封账 epoch 的请求不可撤销，避免破坏结算口径
        if (snapshots[epoch].finalizedAt != 0) {
            revert EpochAlreadyFinalized();
        }

        DepositRequest storage req = depositRequests[epoch][index];
        // 仅请求发起人可撤销
        if (req.investor != msg.sender) {
            revert NotRequestOwner();
        }
        // 仅 Pending 请求可撤销，已结算/已撤销请求禁止重复操作
        if (req.status != ReqStatus.Pending) {
            revert InvalidRequestStatus();
        }

        // 先更新状态再退款，遵循 CEI
        req.status = ReqStatus.Canceled;
        netRequestedDepositAssets[epoch] -= req.amount;

        IERC20(baseAsset).safeTransfer(msg.sender, req.amount);

        emit DepositCanceled(epoch, index, msg.sender, req.amount);
    }

    function cancelRedeem(uint256 epoch, uint256 index) external override nonReentrant {
        // 已封账 epoch 的请求不可撤销，避免破坏结算口径
        if (snapshots[epoch].finalizedAt != 0) {
            revert EpochAlreadyFinalized();
        }

        RedeemRequest storage req = redeemRequests[epoch][index];
        // 仅请求发起人可撤销
        if (req.investor != msg.sender) {
            revert NotRequestOwner();
        }
        // 仅 Pending 请求可撤销，已结算/已撤销请求禁止重复操作
        if (req.status != ReqStatus.Pending) {
            revert InvalidRequestStatus();
        }

        // 先更新状态再解锁份额
        req.status = ReqStatus.Canceled;
        netRequestedRedeemShares[epoch] -= req.shares;

        _transfer(address(this), msg.sender, req.shares);

        emit RedeemCanceled(epoch, index, msg.sender, req.shares);
    }

    function claim(address to) external override nonReentrant returns (uint256 amount) {
        if (to == address(0)) {
            revert ZeroAddress();
        }

        amount = claimableAssets[msg.sender];
        if (amount == 0) {
            revert NoClaimableAssets();
        }

        // 先清零可领取余额，再执行转账，遵循 CEI
        claimableAssets[msg.sender] = 0;
        IERC20(baseAsset).safeTransfer(to, amount);

        emit Claimed(msg.sender, to, amount);
    }

    // ===== 运营操作 =====

    function finalizeEpoch(uint256 epoch, uint256 totalAum) external override onlyRole(OPERATOR_ROLE) {
        uint256 current = _currentEpoch();
        // 尚未初始化的时期，无账可封
        if (epoch < epoch0) {
            revert InvalidFinalizeEpoch();
        }
        // 仅允许封账历史 epoch，当前/未来 epoch 结算口径尚未闭合
        if (epoch >= current) {
            revert InvalidFinalizeEpoch();
        }
        // 同一 epoch 只允许封账一次
        if (snapshots[epoch].finalizedAt != 0) {
            revert EpochAlreadyFinalized();
        }

        // NAV 定价口径要扣除“本期待结算申购资金”，否则会抬高 NAV 并稀释新申购者。
        uint256 pricingAum = totalAum;
        uint256 epochNetDeposits = netRequestedDepositAssets[epoch];
        if (epochNetDeposits > 0) {
            if (pricingAum < epochNetDeposits) {
                revert InvalidTotalAum();
            }
            pricingAum -= epochNetDeposits;
        }

        uint256 sharesAtSettle = totalSupply();
        uint256 navPerShare = sharesAtSettle == 0 ? NAV_SCALE : (pricingAum * NAV_SCALE) / sharesAtSettle;

        // 固化该 epoch 结算口径（AUM、份额、NAV、封账时间）
        snapshots[epoch] = EpochSnapshot({
            totalAum: pricingAum, sharesAtSettle: sharesAtSettle, navPerShare: navPerShare, finalizedAt: block.timestamp
        });

        emit EpochFinalized(epoch, pricingAum, sharesAtSettle, navPerShare);
    }

    function settleDeposits(uint256 epoch, uint256 maxCount) external override onlyRole(OPERATOR_ROLE) {
        if (maxCount == 0) {
            revert InvalidMaxCount();
        }

        EpochSnapshot storage snapshot = snapshots[epoch];
        // 仅允许结算已封账的 epoch
        if (snapshot.finalizedAt == 0) {
            revert InvalidFinalizeEpoch();
        }

        SettlementCursor storage cursor = cursors[epoch];
        if (cursor.depositsDone) {
            revert DepositsSettlementCompleted();
        }

        DepositRequest[] storage requests = depositRequests[epoch];
        uint256 len = requests.length;
        uint256 start = cursor.nextDeposit;

        // 空批次或已到队尾：标记完成并显式 revert，便于脚本感知“无需继续调度”。
        if (start >= len) {
            cursor.depositsDone = true;
            revert DepositsSettlementCompleted();
        }

        uint256 navPerShare = snapshot.navPerShare;
        // 若封账快照 NAV 非法（0），拒绝继续结算，避免除零或错误分配。
        if (navPerShare == 0) {
            revert InvalidFinalizeEpoch();
        }

        uint256 end = start + maxCount;
        if (end > len) {
            end = len;
        }

        for (uint256 i = start; i < end; i++) {
            DepositRequest storage req = requests[i];
            if (req.status != ReqStatus.Pending) {
                continue;
            }

            uint256 shares = (req.amount * NAV_SCALE) / navPerShare;
            req.status = ReqStatus.Settled;
            _mint(req.investor, shares);

            emit DepositSettled(epoch, i, req.investor, shares);
        }

        cursor.nextDeposit = end;
        if (end == len) {
            cursor.depositsDone = true;
        }
    }

    function settleRedeems(uint256 epoch, uint256 maxCount) external override onlyRole(OPERATOR_ROLE) {
        if (maxCount == 0) {
            revert InvalidMaxCount();
        }

        EpochSnapshot storage snapshot = snapshots[epoch];
        // 仅允许结算已封账的 epoch
        if (snapshot.finalizedAt == 0) {
            revert InvalidFinalizeEpoch();
        }

        SettlementCursor storage cursor = cursors[epoch];
        if (cursor.redeemsDone) {
            revert RedeemsSettlementCompleted();
        }

        RedeemRequest[] storage requests = redeemRequests[epoch];
        uint256 len = requests.length;
        uint256 start = cursor.nextRedeem;

        // 空批次或已到队尾：标记完成并显式 revert，便于脚本感知“无需继续调度”。
        if (start >= len) {
            cursor.redeemsDone = true;
            revert RedeemsSettlementCompleted();
        }

        uint256 navPerShare = snapshot.navPerShare;
        // 若封账快照 NAV 非法（0），拒绝继续结算，避免除零或错误分配。
        if (navPerShare == 0) {
            revert InvalidFinalizeEpoch();
        }

        uint256 end = start + maxCount;
        if (end > len) {
            end = len;
        }

        for (uint256 i = start; i < end; i++) {
            RedeemRequest storage req = requests[i];
            if (req.status != ReqStatus.Pending) {
                continue;
            }

            // 先按 NAV 计算可兑资产，再销毁已锁仓份额，资产通过 claimable 走 Pull 模式领取。
            uint256 assets = (req.shares * navPerShare) / NAV_SCALE;
            req.status = ReqStatus.Settled;
            _burn(address(this), req.shares);
            claimableAssets[req.investor] += assets;

            emit RedeemSettled(epoch, i, req.investor, assets);
        }

        cursor.nextRedeem = end;
        if (end == len) {
            cursor.redeemsDone = true;
        }
    }

    function transferToExecutor(uint256 amount) external override onlyRole(OPERATOR_ROLE) {
        IERC20(baseAsset).safeTransfer(executor, amount);
    }

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

    function claimFee(address to) external override nonReentrant returns (uint256 amount) {}

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
