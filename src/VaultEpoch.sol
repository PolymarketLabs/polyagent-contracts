// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IVaultEpoch} from "./interfaces/IVaultEpoch.sol";

abstract contract VaultEpoch is Initializable, IVaultEpoch {
    struct VaultEpochStorage {
        uint256 secondsPerEpoch;
        uint256 epoch0;
    }

    bytes32 private constant EPOCH_STORAGE_LOCATION = keccak256("polyagent.vault.epoch.v1");

    error InvalidSecondsPerEpoch();

    function _vaultEpochStorage() internal pure returns (VaultEpochStorage storage $) {
        bytes32 slot = EPOCH_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function __VaultEpoch_init(uint256 _secondsPerEpoch) internal onlyInitializing {
        if (_secondsPerEpoch == 0) {
            revert InvalidSecondsPerEpoch();
        }

        VaultEpochStorage storage $ = _vaultEpochStorage();
        $.secondsPerEpoch = _secondsPerEpoch;
        $.epoch0 = block.timestamp / _secondsPerEpoch;
    }

    function secondsPerEpoch() public view override returns (uint256) {
        return _vaultEpochStorage().secondsPerEpoch;
    }

    function epoch0() public view override returns (uint256) {
        return _vaultEpochStorage().epoch0;
    }

    function currentEpoch() public view override returns (uint256) {
        return _currentEpoch();
    }

    function _currentEpoch() internal view virtual returns (uint256) {
        VaultEpochStorage storage $ = _vaultEpochStorage();
        return block.timestamp / $.secondsPerEpoch;
    }
}
