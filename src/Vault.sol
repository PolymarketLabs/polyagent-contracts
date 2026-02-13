// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IVault} from "./interfaces/IVault.sol";
import {
    DepositRequest,
    RedeemRequest,
    ReqStatus,
    EpochSnapshot,
    SettlementCursor,
    SplitConfig,
    FeeRecipientConfig,
    FeePolicy,
    FeePolicyCheckpoint
} from "./vault/VaultTypes.sol";
import {VaultEvents} from "./vault/VaultEvents.sol";
import {VaultErrors} from "./vault/VaultErrors.sol";

contract Vault is ERC20Upgradeable, AccessControlUpgradeable, ReentrancyGuard, IVault, VaultEvents, VaultErrors {
    using SafeERC20 for IERC20;
    uint256 private constant NAV_SCALE = 1e18; // 采用 1e18 精度记录 NAV，避免与份额 decimals 耦合
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant SECONDS_PER_YEAR = 365 days;

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
    uint256 public highWaterMarkNav; // 业绩报酬高水位净值（仅对超越该净值的收益计提业绩费）
    FeePolicyCheckpoint[] private feePolicyCheckpoints; // 按生效 epoch 递增存储的策略检查点
    mapping(address => address) public referrers; // 投资者 -> 推荐人（首绑生效）
    mapping(address => uint256) public feeClaimable; // 收款方可领取费用余额
    uint256 public lastFinalizedEpoch; // 最近一次完成封账的 epoch（首次封账前为 0）

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
        depositRequests[epoch].push(DepositRequest({investor: msg.sender, amount: amount, status: ReqStatus.Pending}));
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
        redeemRequests[epoch].push(RedeemRequest({investor: msg.sender, shares: shares, status: ReqStatus.Pending}));
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
        // 已经封过账了，禁止重复处理
        if (epoch <= lastFinalizedEpoch) {
            revert InvalidFinalizeEpoch();
        }
        // 同一 epoch 只允许封账一次
        if (snapshots[epoch].finalizedAt != 0) {
            revert EpochAlreadyFinalized();
        }

        // 管理费按“当前封账 epoch 与上次封账 epoch 的跨度”计提；首次封账按与 epoch0 的跨度计提。
        uint256 deltaEpochs = lastFinalizedEpoch == 0 ? epoch - epoch0 : epoch - lastFinalizedEpoch;
        uint256 deltaSeconds = deltaEpochs * secondsPerEpoch;

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
        FeePolicy memory policy = _getFeePolicyForEpoch(epoch);
        // 封账阶段先计提“管理费 -> 业绩报酬”，再用扣费后的 AUM 计算 NAV。
        pricingAum = _applyEpochLevelFees(pricingAum, sharesAtSettle, policy, deltaSeconds);

        uint256 navPerShare = sharesAtSettle == 0 ? NAV_SCALE : Math.mulDiv(pricingAum, NAV_SCALE, sharesAtSettle);

        // 固化该 epoch 结算口径（AUM、份额、NAV、封账时间）
        snapshots[epoch] = EpochSnapshot({
            totalAum: pricingAum, sharesAtSettle: sharesAtSettle, navPerShare: navPerShare, finalizedAt: block.timestamp
        });
        lastFinalizedEpoch = epoch;

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
        FeePolicy memory policy = _getFeePolicyForEpoch(epoch);

        uint256 end = start + maxCount;
        if (end > len) {
            end = len;
        }

        for (uint256 i = start; i < end; i++) {
            DepositRequest storage req = requests[i];
            if (req.status != ReqStatus.Pending) {
                continue;
            }
            _settleDepositRequest(epoch, i, req, navPerShare, policy);
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
        FeePolicy memory policy = _getFeePolicyForEpoch(epoch);

        uint256 end = start + maxCount;
        if (end > len) {
            end = len;
        }

        for (uint256 i = start; i < end; i++) {
            RedeemRequest storage req = requests[i];
            if (req.status != ReqStatus.Pending) {
                continue;
            }
            _settleRedeemRequest(epoch, i, req, navPerShare, policy);
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

    function pauseDeposit() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (depositPaused) {
            revert DepositPaused();
        }
        depositPaused = true;
        emit DepositPauseStatusUpdated(msg.sender, true);
    }

    function unpauseDeposit() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!depositPaused) {
            revert DepositNotPaused();
        }
        depositPaused = false;
        emit DepositPauseStatusUpdated(msg.sender, false);
    }

    function pauseRedeem() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (redeemPaused) {
            revert RedeemPaused();
        }
        redeemPaused = true;
        emit RedeemPauseStatusUpdated(msg.sender, true);
    }

    function unpauseRedeem() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!redeemPaused) {
            revert RedeemNotPaused();
        }
        redeemPaused = false;
        emit RedeemPauseStatusUpdated(msg.sender, false);
    }

    function scheduleFeePolicy(FeePolicy calldata policy, uint256 effectiveEpoch)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        // 配置落盘前先做结构化校验，避免无效策略进入 checkpoint。
        _validateFeePolicy(policy);
        // 历史 epoch 口径已形成，禁止补录回填策略。
        if (effectiveEpoch < _currentEpoch()) {
            revert InvalidEffectiveEpoch();
        }

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

    function claimFee(address to) external override nonReentrant returns (uint256 amount) {
        if (to == address(0)) {
            revert ZeroAddress();
        }

        amount = feeClaimable[msg.sender];
        if (amount == 0) {
            revert NoClaimableFee();
        }

        // 先清零可领取余额，再执行转账，遵循 CEI。
        feeClaimable[msg.sender] = 0;
        IERC20(baseAsset).safeTransfer(to, amount);

        emit FeeClaimed(msg.sender, to, amount);
    }

    // ===== 只读查询 =====

    function currentEpoch() external view override returns (uint256) {
        return _currentEpoch();
    }

    function initializedVersion() external view override returns (uint64) {
        return _getInitializedVersion();
    }

    function depositRequestCount(uint256 epoch) external view override returns (uint256) {
        return depositRequests[epoch].length;
    }

    function redeemRequestCount(uint256 epoch) external view override returns (uint256) {
        return redeemRequests[epoch].length;
    }

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
        FeePolicy memory policy = _getFeePolicyForEpoch(_currentEpoch());
        return _calcFeeAndNetAmount(amount, policy.rates.entryFeeBps);
    }

    function previewExitFee(uint256 amount) external view override returns (uint256 fee, uint256 netAmount) {
        FeePolicy memory policy = _getFeePolicyForEpoch(_currentEpoch());
        return _calcFeeAndNetAmount(amount, policy.rates.exitFeeBps);
    }

    function _getFeePolicyForEpoch(uint256 epoch) internal view returns (FeePolicy memory policy) {
        uint256 len = feePolicyCheckpoints.length;
        for (uint256 i = len; i > 0; i--) {
            FeePolicyCheckpoint storage checkpoint = feePolicyCheckpoints[i - 1];
            if (checkpoint.effectiveEpoch <= epoch) {
                return checkpoint.policy;
            }
        }
        revert FeePolicyNotFound();
    }

    function _validateFeePolicy(FeePolicy calldata policy) internal pure {
        // reserve 作为统一兜底收款地址（无推荐人分成 + rounding remainder），必须始终存在。
        if (policy.recipients.reserve == address(0)) {
            revert ZeroAddress();
        }

        _validateBps(policy.rates.entryFeeBps);
        _validateBps(policy.rates.exitFeeBps);
        _validateBps(policy.rates.mgmtFeeAnnualBps);
        _validateBps(policy.rates.performanceFeeBps);

        _validateSplit(policy.entrySplit);
        _validateSplit(policy.exitSplit);
        _validateSplit(policy.mgmtSplit);
        _validateSplit(policy.performanceSplit);

        _validateRecipientsForActiveSplit(policy.recipients, policy.entrySplit, policy.rates.entryFeeBps);
        _validateRecipientsForActiveSplit(policy.recipients, policy.exitSplit, policy.rates.exitFeeBps);
        _validateRecipientsForActiveSplit(policy.recipients, policy.mgmtSplit, policy.rates.mgmtFeeAnnualBps);
        _validateRecipientsForActiveSplit(policy.recipients, policy.performanceSplit, policy.rates.performanceFeeBps);
    }

    function _validateBps(uint16 bps) internal pure {
        if (bps > BPS_DENOMINATOR) {
            revert InvalidBps();
        }
    }

    function _validateSplit(SplitConfig calldata splitConfig) internal pure returns (uint256 sum) {
        _validateBps(splitConfig.platformBps);
        _validateBps(splitConfig.referrerBps);
        _validateBps(splitConfig.managerBps);

        sum = uint256(splitConfig.platformBps) + uint256(splitConfig.referrerBps) + uint256(splitConfig.managerBps);
        if (sum > BPS_DENOMINATOR) {
            revert InvalidSplit();
        }
    }

    function _validateRecipientsForActiveSplit(
        FeeRecipientConfig calldata recipients,
        SplitConfig calldata splitConfig,
        uint16 feeRateBps
    ) internal pure {
        // 仅在该类费用启用时校验对应收款地址，未启用的费率允许地址暂未配置。
        if (feeRateBps == 0) {
            return;
        }

        if (splitConfig.platformBps > 0 && recipients.platform == address(0)) {
            revert ZeroAddress();
        }
        if (splitConfig.managerBps > 0 && recipients.manager == address(0)) {
            revert ZeroAddress();
        }
    }

    function _applyEpochLevelFees(
        uint256 pricingAum,
        uint256 sharesAtSettle,
        FeePolicy memory policy,
        uint256 deltaSeconds
    ) internal returns (uint256 pricingAumAfterFee) {
        // 管理费按 epoch 时长从年化费率折算。
        uint256 mgmtFee = _calcMgmtFee(pricingAum, policy.rates.mgmtFeeAnnualBps, deltaSeconds);
        if (mgmtFee > pricingAum) {
            mgmtFee = pricingAum;
        }

        uint256 aumAfterMgmt = pricingAum - mgmtFee;

        // 业绩报酬以“管理费后 NAV 相对高水位的超额收益”计提。
        uint256 performanceFee = _calcPerformanceFee(aumAfterMgmt, sharesAtSettle, policy.rates.performanceFeeBps);
        if (performanceFee > aumAfterMgmt) {
            performanceFee = aumAfterMgmt;
        }

        pricingAumAfterFee = aumAfterMgmt - performanceFee;

        if (mgmtFee > 0) {
            _accrueFeeBySplit(policy.recipients, policy.mgmtSplit, address(0), mgmtFee);
        }
        if (performanceFee > 0) {
            _accrueFeeBySplit(policy.recipients, policy.performanceSplit, address(0), performanceFee);
        }

        // 高水位使用“封账后净 NAV”更新，确保下一期只对新增超额收益收费。
        _updateHighWaterMark(pricingAumAfterFee, sharesAtSettle);
    }

    function _settleDepositRequest(
        uint256 epoch,
        uint256 requestIndex,
        DepositRequest storage req,
        uint256 navPerShare,
        FeePolicy memory policy
    ) internal {
        uint16 entryFeeBps = policy.rates.entryFeeBps;
        (uint256 entryFee, uint256 netAmount) = _calcFeeAndNetAmount(req.amount, entryFeeBps);
        if (entryFee > 0) {
            _accrueFeeBySplit(policy.recipients, policy.entrySplit, req.investor, entryFee);
        }

        uint256 shares = (netAmount * NAV_SCALE) / navPerShare;
        req.status = ReqStatus.Settled;
        _mint(req.investor, shares);

        emit DepositSettled(epoch, requestIndex, req.investor, shares);
    }

    function _settleRedeemRequest(
        uint256 epoch,
        uint256 requestIndex,
        RedeemRequest storage req,
        uint256 navPerShare,
        FeePolicy memory policy
    ) internal {
        // 先按 NAV 计算赎回总资产，再扣除 EXIT 费用，净额进入 claimable 供用户领取。
        uint256 grossAssets = (req.shares * navPerShare) / NAV_SCALE;
        uint16 exitFeeBps = policy.rates.exitFeeBps;
        (uint256 exitFee, uint256 netAssets) = _calcFeeAndNetAmount(grossAssets, exitFeeBps);
        if (exitFee > 0) {
            _accrueFeeBySplit(policy.recipients, policy.exitSplit, req.investor, exitFee);
        }

        req.status = ReqStatus.Settled;
        _burn(address(this), req.shares);
        claimableAssets[req.investor] += netAssets;

        emit RedeemSettled(epoch, requestIndex, req.investor, netAssets);
    }

    function _accrueFeeBySplit(
        FeeRecipientConfig memory recipients,
        SplitConfig memory splitConfig,
        address investor,
        uint256 fee
    ) internal {
        if (fee == 0) {
            return;
        }

        (uint256 platformAmount, uint256 referrerAmount, uint256 managerAmount, uint256 remainderAmount) =
            _splitFee(fee, splitConfig);

        address platformRecipient = recipients.platform;
        address managerRecipient = recipients.manager;
        address reserveRecipient = recipients.reserve;
        address referrerRecipient = referrers[investor];
        // 无推荐人时，推荐人份额回流 reserve。
        if (referrerRecipient == address(0)) {
            referrerRecipient = reserveRecipient;
        }

        _accrueFee(platformRecipient, platformAmount);
        _accrueFee(referrerRecipient, referrerAmount);
        _accrueFee(managerRecipient, managerAmount);
        _accrueFee(reserveRecipient, remainderAmount);
    }

    function _calcFeeAndNetAmount(uint256 amount, uint16 feeBps)
        internal
        pure
        returns (uint256 fee, uint256 netAmount)
    {
        if (feeBps == 0) {
            return (0, amount);
        }

        fee = (amount * feeBps) / BPS_DENOMINATOR;
        netAmount = amount - fee;
    }

    function _calcMgmtFee(uint256 pricingAum, uint16 mgmtFeeAnnualBps, uint256 deltaSeconds)
        internal
        pure
        returns (uint256 fee)
    {
        if (pricingAum == 0 || mgmtFeeAnnualBps == 0 || deltaSeconds == 0) {
            return 0;
        }

        // fee = AUM * annualBps * deltaSeconds / (10000 * 365 days)
        uint256 annualBpsTimesDelta = uint256(mgmtFeeAnnualBps) * deltaSeconds;
        fee = Math.mulDiv(pricingAum, annualBpsTimesDelta, BPS_DENOMINATOR * SECONDS_PER_YEAR);
    }

    function _calcPerformanceFee(uint256 pricingAum, uint256 sharesAtSettle, uint16 performanceFeeBps)
        internal
        view
        returns (uint256 fee)
    {
        if (pricingAum == 0 || sharesAtSettle == 0 || performanceFeeBps == 0) {
            return 0;
        }
        // 尚未形成高水位基线时不收业绩报酬。
        if (highWaterMarkNav == 0) {
            return 0;
        }

        uint256 navPerShareBeforePerformanceFee = Math.mulDiv(pricingAum, NAV_SCALE, sharesAtSettle);
        if (navPerShareBeforePerformanceFee <= highWaterMarkNav) {
            return 0;
        }

        uint256 gainPerShare = navPerShareBeforePerformanceFee - highWaterMarkNav;
        uint256 gainAum = Math.mulDiv(gainPerShare, sharesAtSettle, NAV_SCALE);
        fee = Math.mulDiv(gainAum, performanceFeeBps, BPS_DENOMINATOR);
    }

    function _updateHighWaterMark(uint256 pricingAum, uint256 sharesAtSettle) internal {
        if (sharesAtSettle == 0) {
            return;
        }

        // 高水位单调不降。
        uint256 navPerShare = Math.mulDiv(pricingAum, NAV_SCALE, sharesAtSettle);
        if (navPerShare > highWaterMarkNav) {
            highWaterMarkNav = navPerShare;
        }
    }

    function _splitFee(uint256 fee, SplitConfig memory splitConfig)
        internal
        pure
        returns (uint256 platformAmount, uint256 referrerAmount, uint256 managerAmount, uint256 remainderAmount)
    {
        if (fee == 0) {
            return (0, 0, 0, 0);
        }

        platformAmount = (fee * splitConfig.platformBps) / BPS_DENOMINATOR;
        referrerAmount = (fee * splitConfig.referrerBps) / BPS_DENOMINATOR;
        managerAmount = (fee * splitConfig.managerBps) / BPS_DENOMINATOR;

        uint256 distributed = platformAmount + referrerAmount + managerAmount;
        remainderAmount = fee - distributed;
    }

    function _accrueFee(address recipient, uint256 amount) internal {
        if (recipient == address(0) || amount == 0) {
            return;
        }
        feeClaimable[recipient] += amount;
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
