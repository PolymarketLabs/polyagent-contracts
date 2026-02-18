// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Vault} from "./Vault.sol";

contract VaultV2 is Vault {
    /// @notice V2 initializer entrypoint, callable once by admin to advance initialized version to 2.
    function initializeV2() external reinitializer(2) onlyRole(DEFAULT_ADMIN_ROLE) {}
}
