// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {VaultFactory} from "./VaultFactory.sol";

contract VaultFactoryV2 is VaultFactory {
    /// @notice V2 initializer entrypoint, callable once by owner to advance initialized version to 2.
    function initializeV2() external reinitializer(2) onlyOwner {}
}
