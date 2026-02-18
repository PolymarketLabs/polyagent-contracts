// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

interface IVaultAccess {
    event AdminUpdated(address indexed previousAdmin, address indexed newAdmin);
    event OperatorUpdated(address indexed previousOperator, address indexed newOperator);
    event ExecutorUpdated(address indexed previousExecutor, address indexed newExecutor);

    // write functions
    function setAdmin(address newAdmin) external;

    function setOperator(address newOperator) external;

    function setExecutor(address newExecutor) external;

    // read functions
    function admin() external view returns (address);

    function operator() external view returns (address);

    function executor() external view returns (address);
}
