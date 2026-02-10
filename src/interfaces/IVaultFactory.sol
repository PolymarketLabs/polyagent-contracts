// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

interface IVaultFactory {
    /// @notice 创建并初始化一个新的基金 Vault（仅工厂 owner 可调用）
    /// @param tokenName 份额代币名称
    /// @param tokenSymbol 份额代币符号
    /// @param baseAsset 基础资产地址
    /// @param manager 基金经理地址
    /// @param admin Vault 管理员地址
    /// @param operator Vault 运营地址
    /// @param executor Vault 执行钱包地址
    /// @param secondsPerEpoch 结算周期长度（秒）
    /// @return vault 新建 Vault 代理地址
    function createFund(
        string memory tokenName,
        string memory tokenSymbol,
        address baseAsset,
        address manager,
        address admin,
        address operator,
        address executor,
        uint256 secondsPerEpoch
    ) external returns (address vault);

    /// @notice 返回已创建基金总数
    function totalFunds() external view returns (uint256);
}
