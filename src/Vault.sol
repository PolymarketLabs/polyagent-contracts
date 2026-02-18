// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVault} from "./interfaces/IVault.sol";
import {AddressLib} from "./VaultLib.sol";
import {VaultSettlement} from "./VaultSettlement.sol";

contract Vault is Initializable, ERC20Upgradeable, VaultSettlement, IVault {
    using SafeERC20 for IERC20;

    struct VaultStorage {
        address baseAsset;
    }

    bytes32 private constant VAULT_STORAGE_LOCATION = keccak256("polyagent.vault.core.v1");

    function _vaultStorage() internal pure returns (VaultStorage storage $) {
        bytes32 slot = VAULT_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory tokenName,
        string memory tokenSymbol,
        address baseAsset_,
        address initialAdmin,
        address initialOperator,
        address initialExecutor,
        uint256 secondsPerEpoch_,
        uint256 initialMinDepositAmount,
        uint256 initialMinRedeemShares
    ) external override initializer {
        AddressLib.requireContract(baseAsset_);

        __ERC20_init(tokenName, tokenSymbol);
        __VaultAccess_init(initialAdmin, initialOperator, initialExecutor);
        __VaultEpoch_init(secondsPerEpoch_);
        __VaultUser_init(initialMinDepositAmount, initialMinRedeemShares);

        _vaultStorage().baseAsset = baseAsset_;
    }

    function transferBaseAssetToExecutor(uint256 amount) external override nonReentrant onlyRole(OPERATOR_ROLE) {
        address currentExecutor = _vaultAccessStorage().executor;
        _transferBaseAssetTo(currentExecutor, amount);
        emit BaseAssetTransferredToExecutor(_msgSender(), currentExecutor, amount);
    }

    // read functions
    function initializedVersion() external view override returns (uint64) {
        return _getInitializedVersion();
    }

    function baseAsset() external view override returns (address) {
        return _vaultStorage().baseAsset;
    }

    // internal functions
    function _transferBaseAssetFrom(address from, uint256 amount) internal override {
        IERC20 baseAsset_ = IERC20(_vaultStorage().baseAsset);
        baseAsset_.safeTransferFrom(from, address(this), amount);
    }

    function _transferBaseAssetTo(address to, uint256 amount) internal override {
        IERC20 baseAsset_ = IERC20(_vaultStorage().baseAsset);
        baseAsset_.safeTransfer(to, amount);
    }

    function _transferShares(address from, address to, uint256 shares) internal override {
        _transfer(from, to, shares);
    }

    function _sharesAtSettle() internal view override returns (uint256) {
        return totalSupply();
    }

    function _mintShares(address to, uint256 shares) internal override {
        _mint(to, shares);
    }

    function _burnShares(address from, uint256 shares) internal override {
        _burn(from, shares);
    }
}
