// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IVaultAccess} from "./interfaces/IVaultAccess.sol";
import {AddressLib} from "./VaultLib.sol";

abstract contract VaultAccess is AccessControlUpgradeable, IVaultAccess {
    struct VaultAccessStorage {
        address admin;
        address operator;
        address executor;
    }

    bytes32 private constant ACCESS_STORAGE_LOCATION = keccak256("polyagent.vault.access.v1");

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    function _vaultAccessStorage() internal pure returns (VaultAccessStorage storage $) {
        bytes32 slot = ACCESS_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function __VaultAccess_init(address initialAdmin, address initialOperator, address initialExecutor)
        internal
        onlyInitializing
    {
        __AccessControl_init();

        AddressLib.requireNonZeroAddress(initialAdmin);
        AddressLib.requireNonZeroAddress(initialOperator);
        AddressLib.requireNonZeroAddress(initialExecutor);

        VaultAccessStorage storage $ = _vaultAccessStorage();
        $.admin = initialAdmin;
        $.operator = initialOperator;
        $.executor = initialExecutor;

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(OPERATOR_ROLE, initialOperator);
    }

    // read functions
    function admin() external view virtual override returns (address) {
        return _vaultAccessStorage().admin;
    }

    function operator() external view virtual override returns (address) {
        return _vaultAccessStorage().operator;
    }

    function executor() external view virtual override returns (address) {
        return _vaultAccessStorage().executor;
    }

    // write functions
    function setAdmin(address newAdmin) external virtual override onlyRole(DEFAULT_ADMIN_ROLE) {
        AddressLib.requireNonZeroAddress(newAdmin);

        VaultAccessStorage storage $ = _vaultAccessStorage();
        address previousAdmin = $.admin;
        if (newAdmin == previousAdmin) {
            return;
        }

        _grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        _revokeRole(DEFAULT_ADMIN_ROLE, previousAdmin);
        $.admin = newAdmin;

        emit AdminUpdated(previousAdmin, newAdmin);
    }

    function setOperator(address newOperator) external virtual override onlyRole(DEFAULT_ADMIN_ROLE) {
        AddressLib.requireNonZeroAddress(newOperator);

        VaultAccessStorage storage $ = _vaultAccessStorage();
        address previousOperator = $.operator;
        if (newOperator == previousOperator) {
            return;
        }

        _grantRole(OPERATOR_ROLE, newOperator);
        _revokeRole(OPERATOR_ROLE, previousOperator);
        $.operator = newOperator;

        emit OperatorUpdated(previousOperator, newOperator);
    }

    function setExecutor(address newExecutor) external virtual override onlyRole(DEFAULT_ADMIN_ROLE) {
        AddressLib.requireNonZeroAddress(newExecutor);

        VaultAccessStorage storage $ = _vaultAccessStorage();
        address previousExecutor = $.executor;
        if (newExecutor == previousExecutor) {
            return;
        }

        $.executor = newExecutor;

        emit ExecutorUpdated(previousExecutor, newExecutor);
    }
}
