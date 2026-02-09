// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Vault} from "./Vault.sol";

contract VaultV2 is Vault {
    /// @notice V2 初始化入口，仅管理员可调用一次，用于推进初始化版本号到2
    function initializeV2() external reinitializer(2) onlyRole(DEFAULT_ADMIN_ROLE) {}
}
