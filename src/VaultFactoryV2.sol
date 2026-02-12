// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {VaultFactory} from "./VaultFactory.sol";

contract VaultFactoryV2 is VaultFactory {
    /// @notice V2 初始化入口，仅 owner 可调用一次，用于推进初始化版本号到 2
    function initializeV2() external reinitializer(2) onlyOwner {}
}
