// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {FeePolicy} from "../vault/VaultTypes.sol";

interface IVault {
    /// @notice 初始化 Vault 基础配置与角色绑定
    /// @param tokenName 份额代币名称
    /// @param tokenSymbol 份额代币符号
    /// @param _baseAsset 基础资产地址（如 USDC）
    /// @param _admin 默认管理员地址
    /// @param _operator 运营角色地址
    /// @param _executor 执行钱包地址
    /// @param _secondsPerEpoch 每个结算周期长度（秒）
    function initialize(
        string memory tokenName,
        string memory tokenSymbol,
        address _baseAsset,
        address _admin,
        address _operator,
        address _executor,
        uint256 _secondsPerEpoch
    ) external;

    /// @notice 提交申购请求（仅登记，不在此函数内完成结算铸币）
    /// @dev referrer 仅在用户尚未绑定推荐人时生效；已绑定则忽略
    /// @param amount 申购金额
    /// @param referrer 推荐人地址（可为零地址）
    /// @return epoch 请求归属的 epoch
    /// @return index 该 epoch 下请求索引
    function requestDeposit(uint256 amount, address referrer) external returns (uint256 epoch, uint256 index);

    /// @notice 提交赎回请求（仅登记，不在此函数内完成结算）
    /// @param shares 赎回份额
    /// @return epoch 请求归属的 epoch
    /// @return index 该 epoch 下请求索引
    function requestRedeem(uint256 shares) external returns (uint256 epoch, uint256 index);

    /// @notice 撤销未结算的申购请求
    /// @param epoch 请求所在 epoch
    /// @param index 请求索引
    function cancelDeposit(uint256 epoch, uint256 index) external;

    /// @notice 撤销未结算的赎回请求
    /// @param epoch 请求所在 epoch
    /// @param index 请求索引
    function cancelRedeem(uint256 epoch, uint256 index) external;

    /// @notice 领取已结算赎回对应的可领取基础资产
    /// @param to 收款地址
    /// @return amount 实际领取金额
    function claim(address to) external returns (uint256 amount);

    /// @notice 封账指定 epoch，写入结算快照
    /// @param epoch 待封账 epoch（通常应小于当前 epoch）
    /// @param totalAum 该 epoch 对应总资产
    function finalizeEpoch(uint256 epoch, uint256 totalAum) external;

    /// @notice 分批结算申购请求
    /// @param epoch 待结算 epoch
    /// @param maxCount 本批最多处理条数
    function settleDeposits(uint256 epoch, uint256 maxCount) external;

    /// @notice 分批结算赎回请求
    /// @param epoch 待结算 epoch
    /// @param maxCount 本批最多处理条数
    function settleRedeems(uint256 epoch, uint256 maxCount) external;

    /// @notice 将基础资产划转到执行钱包
    /// @param amount 划转金额
    function transferToExecutor(uint256 amount) external;

    /// @notice 更新默认管理员地址，并迁移 DEFAULT_ADMIN_ROLE
    /// @param newAdmin 新管理员地址
    function setAdmin(address newAdmin) external;

    /// @notice 更新运营地址，并迁移 OPERATOR_ROLE
    /// @param newOperator 新运营地址
    function setOperator(address newOperator) external;

    /// @notice 更新执行钱包地址
    /// @param newExecutor 新执行钱包地址
    function setExecutor(address newExecutor) external;

    /// @notice 暂停申购
    function pauseDeposit() external;
    /// @notice 恢复申购
    function unpauseDeposit() external;
    /// @notice 暂停赎回
    function pauseRedeem() external;
    /// @notice 恢复赎回
    function unpauseRedeem() external;

    /// @notice 预约某个 epoch 生效的完整费用策略（费率+分账+收款地址）
    /// @param policy 收费策略快照
    /// @param effectiveEpoch 策略生效 epoch（要求按时间递增）
    function scheduleFeePolicy(FeePolicy calldata policy, uint256 effectiveEpoch) external;

    /// @notice 主动绑定推荐人（仅首次绑定生效）
    /// @param referrer 推荐人地址
    function bindReferrer(address referrer) external;

    /// @notice 领取累计费用分成
    /// @param to 收款地址
    /// @return amount 实际领取金额
    function claimFee(address to) external returns (uint256 amount);

    /// @notice 查询当前 epoch
    function currentEpoch() external view returns (uint256);
    /// @notice 查询初始化版本号（initializer/reinitializer）
    function initializedVersion() external view returns (uint64);
    /// @notice 查询某 epoch 的申购请求数量
    function depositRequestCount(uint256 epoch) external view returns (uint256);
    /// @notice 查询某 epoch 的赎回请求数量
    function redeemRequestCount(uint256 epoch) external view returns (uint256);
    /// @notice 查询投资者已绑定推荐人地址
    function referrerOf(address investor) external view returns (address);
    /// @notice 查询地址可领取费用金额
    function feeClaimableOf(address recipient) external view returns (uint256);
    /// @notice 查询当前生效费用策略（从末尾向前查找第一个 effectiveEpoch <= currentEpoch）
    function currentFeePolicy() external view returns (FeePolicy memory);
    /// @notice 预览申购费用与净申购额（不修改状态）
    function previewEntryFee(uint256 amount) external view returns (uint256 fee, uint256 netAmount);
    /// @notice 预览赎回费用与净赎回额（不修改状态）
    function previewExitFee(uint256 amount) external view returns (uint256 fee, uint256 netAmount);
}
