// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {VaultAccess} from "./VaultAccess.sol";
import {IVaultPausable} from "./interfaces/IVaultPausable.sol";

abstract contract VaultPausable is VaultAccess, IVaultPausable {
    struct VaultPausableStorage {
        bool depositPaused;
        bool redeemPaused;
    }

    bytes32 private constant PAUSABLE_STORAGE_LOCATION = keccak256("polyagent.vault.pausable.v1");

    error DepositPaused();
    error DepositNotPaused();
    error RedeemPaused();
    error RedeemNotPaused();

    function _vaultPausableStorage() internal pure returns (VaultPausableStorage storage $) {
        bytes32 slot = PAUSABLE_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    modifier whenDepositNotPaused() {
        _whenDepositNotPaused();
        _;
    }

    modifier whenRedeemNotPaused() {
        _whenRedeemNotPaused();
        _;
    }

    // read functions
    function depositPaused() external view virtual override returns (bool) {
        return _vaultPausableStorage().depositPaused;
    }

    function redeemPaused() external view virtual override returns (bool) {
        return _vaultPausableStorage().redeemPaused;
    }

    // write functions
    function pauseDeposit() external virtual override onlyRole(DEFAULT_ADMIN_ROLE) {
        VaultPausableStorage storage $ = _vaultPausableStorage();
        if ($.depositPaused) {
            revert DepositPaused();
        }
        $.depositPaused = true;
        emit DepositPauseStatusUpdated(_msgSender(), true);
    }

    function unpauseDeposit() external virtual override onlyRole(DEFAULT_ADMIN_ROLE) {
        VaultPausableStorage storage $ = _vaultPausableStorage();
        if (!$.depositPaused) {
            revert DepositNotPaused();
        }
        $.depositPaused = false;
        emit DepositPauseStatusUpdated(_msgSender(), false);
    }

    function pauseRedeem() external virtual override onlyRole(DEFAULT_ADMIN_ROLE) {
        VaultPausableStorage storage $ = _vaultPausableStorage();
        if ($.redeemPaused) {
            revert RedeemPaused();
        }
        $.redeemPaused = true;
        emit RedeemPauseStatusUpdated(_msgSender(), true);
    }

    function unpauseRedeem() external virtual override onlyRole(DEFAULT_ADMIN_ROLE) {
        VaultPausableStorage storage $ = _vaultPausableStorage();
        if (!$.redeemPaused) {
            revert RedeemNotPaused();
        }
        $.redeemPaused = false;
        emit RedeemPauseStatusUpdated(_msgSender(), false);
    }

    // internal validation functions
    function _whenDepositNotPaused() internal view {
        if (_vaultPausableStorage().depositPaused) {
            revert DepositPaused();
        }
    }

    function _whenRedeemNotPaused() internal view {
        if (_vaultPausableStorage().redeemPaused) {
            revert RedeemPaused();
        }
    }
}
