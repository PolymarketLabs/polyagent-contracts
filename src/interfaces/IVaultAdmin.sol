// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

interface IVaultAdmin {
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
}
