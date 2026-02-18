// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IVaultUser} from "./interfaces/IVaultUser.sol";
import {AddressLib} from "./VaultLib.sol";
import {VaultPausable} from "./VaultPausable.sol";
import {VaultEpoch} from "./VaultEpoch.sol";

abstract contract VaultUser is VaultPausable, VaultEpoch, ReentrancyGuard, IVaultUser {
    struct VaultUserStorage {
        mapping(address => uint256) claimableAssets;
        mapping(uint256 => DepositRequest[]) depositRequests;
        mapping(uint256 => RedeemRequest[]) redeemRequests;
        mapping(uint256 => uint256) netRequestedDepositAssets;
        mapping(uint256 => uint256) netRequestedRedeemShares;
        mapping(address => address) referrers;
        uint256 minDepositAmount;
        uint256 minRedeemShares;
    }

    bytes32 private constant USER_STORAGE_LOCATION = keccak256("polyagent.vault.user.v1");

    error AmountTooSmall();
    error NotRequestOwner();
    error EpochAlreadyFinalized();
    error InvalidRequestStatus();
    error NoClaimableAssets();
    error SelfReferral();
    error CircularReferral();

    function _vaultUserStorage() internal pure returns (VaultUserStorage storage $) {
        bytes32 slot = USER_STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function __VaultUser_init(uint256 initialMinDepositAmount, uint256 initialMinRedeemShares)
        internal
        onlyInitializing
    {
        VaultUserStorage storage $ = _vaultUserStorage();
        $.minDepositAmount = initialMinDepositAmount;
        $.minRedeemShares = initialMinRedeemShares;
    }

    // write functions
    function requestDeposit(uint256 amount, address referrer)
        external
        virtual
        override
        nonReentrant
        whenDepositNotPaused
        returns (uint256 epoch, uint256 index)
    {
        VaultUserStorage storage $ = _vaultUserStorage();
        if (amount < $.minDepositAmount) {
            revert AmountTooSmall();
        }

        address sender = _msgSender();
        _bindReferrerIfUnbound(sender, referrer);

        epoch = _currentEpoch();
        index = $.depositRequests[epoch].length;
        $.depositRequests[epoch].push(DepositRequest({investor: sender, amount: amount, status: ReqStatus.Pending}));
        $.netRequestedDepositAssets[epoch] += amount;

        _transferBaseAssetFrom(sender, amount);
        emit DepositRequested(epoch, index, sender, amount);
    }

    function requestRedeem(uint256 shares)
        external
        virtual
        override
        nonReentrant
        whenRedeemNotPaused
        returns (uint256 epoch, uint256 index)
    {
        VaultUserStorage storage $ = _vaultUserStorage();
        if (shares < $.minRedeemShares) {
            revert AmountTooSmall();
        }

        address sender = _msgSender();
        _transferShares(sender, address(this), shares);

        epoch = _currentEpoch();
        index = $.redeemRequests[epoch].length;
        $.redeemRequests[epoch].push(RedeemRequest({investor: sender, shares: shares, status: ReqStatus.Pending}));
        $.netRequestedRedeemShares[epoch] += shares;

        emit RedeemRequested(epoch, index, sender, shares);
    }

    function cancelDeposit(uint256 epoch, uint256 index) external virtual override nonReentrant {
        VaultUserStorage storage $ = _vaultUserStorage();
        DepositRequest storage req = $.depositRequests[epoch][index];
        address sender = _msgSender();

        if (req.investor != sender) {
            revert NotRequestOwner();
        }
        if (_isEpochFinalized(epoch)) {
            revert EpochAlreadyFinalized();
        }
        if (req.status != ReqStatus.Pending) {
            revert InvalidRequestStatus();
        }

        req.status = ReqStatus.Canceled;
        $.netRequestedDepositAssets[epoch] -= req.amount;
        _transferBaseAssetTo(sender, req.amount);

        emit DepositCanceled(epoch, index, sender, req.amount);
    }

    function cancelRedeem(uint256 epoch, uint256 index) external virtual override nonReentrant {
        VaultUserStorage storage $ = _vaultUserStorage();
        RedeemRequest storage req = $.redeemRequests[epoch][index];
        address sender = _msgSender();

        if (req.investor != sender) {
            revert NotRequestOwner();
        }
        if (_isEpochFinalized(epoch)) {
            revert EpochAlreadyFinalized();
        }
        if (req.status != ReqStatus.Pending) {
            revert InvalidRequestStatus();
        }

        req.status = ReqStatus.Canceled;
        $.netRequestedRedeemShares[epoch] -= req.shares;
        _transferShares(address(this), sender, req.shares);

        emit RedeemCanceled(epoch, index, sender, req.shares);
    }

    function claim(address to) external virtual override nonReentrant returns (uint256 amount) {
        AddressLib.requireNonZeroAddress(to);

        VaultUserStorage storage $ = _vaultUserStorage();
        address sender = _msgSender();
        amount = $.claimableAssets[sender];
        if (amount == 0) {
            revert NoClaimableAssets();
        }

        $.claimableAssets[sender] = 0;
        _transferBaseAssetTo(to, amount);
        emit Claimed(sender, to, amount);
    }

    function bindReferrer(address referrer) external virtual override {
        _bindReferrerIfUnbound(_msgSender(), referrer);
    }

    function setMinDepositAmount(uint256 newMinDepositAmount) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMinDepositAmount == 0) {
            revert AmountTooSmall();
        }
        VaultUserStorage storage $ = _vaultUserStorage();
        uint256 previousValue = $.minDepositAmount;
        $.minDepositAmount = newMinDepositAmount;
        emit MinDepositAmountUpdated(previousValue, newMinDepositAmount);
    }

    function setMinRedeemShares(uint256 newMinRedeemShares) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMinRedeemShares == 0) {
            revert AmountTooSmall();
        }
        VaultUserStorage storage $ = _vaultUserStorage();
        uint256 previousValue = $.minRedeemShares;
        $.minRedeemShares = newMinRedeemShares;
        emit MinRedeemSharesUpdated(previousValue, newMinRedeemShares);
    }

    // read functions
    function minDepositAmount() external view override returns (uint256) {
        return _vaultUserStorage().minDepositAmount;
    }

    function minRedeemShares() external view override returns (uint256) {
        return _vaultUserStorage().minRedeemShares;
    }

    function claimableAssets(address investor) external view override returns (uint256) {
        return _vaultUserStorage().claimableAssets[investor];
    }

    function referrerOf(address investor) external view override returns (address) {
        return _vaultUserStorage().referrers[investor];
    }

    function netRequestedDepositAssets(uint256 epoch) external view override returns (uint256) {
        return _vaultUserStorage().netRequestedDepositAssets[epoch];
    }

    function netRequestedRedeemShares(uint256 epoch) external view override returns (uint256) {
        return _vaultUserStorage().netRequestedRedeemShares[epoch];
    }

    function depositRequestCount(uint256 epoch) external view override returns (uint256) {
        return _vaultUserStorage().depositRequests[epoch].length;
    }

    function redeemRequestCount(uint256 epoch) external view override returns (uint256) {
        return _vaultUserStorage().redeemRequests[epoch].length;
    }

    function depositRequestAt(uint256 epoch, uint256 index)
        external
        view
        override
        returns (address investor, uint256 amount, ReqStatus status)
    {
        DepositRequest storage req = _vaultUserStorage().depositRequests[epoch][index];
        return (req.investor, req.amount, req.status);
    }

    function redeemRequestAt(uint256 epoch, uint256 index)
        external
        view
        override
        returns (address investor, uint256 shares, ReqStatus status)
    {
        RedeemRequest storage req = _vaultUserStorage().redeemRequests[epoch][index];
        return (req.investor, req.shares, req.status);
    }

    // internal functions
    function _bindReferrerIfUnbound(address investor, address referrer) internal {
        if (referrer == address(0)) {
            return;
        }
        if (investor == referrer) {
            revert SelfReferral();
        }

        VaultUserStorage storage $ = _vaultUserStorage();
        if ($.referrers[referrer] == investor) {
            revert CircularReferral();
        }
        if ($.referrers[investor] != address(0)) {
            return;
        }

        $.referrers[investor] = referrer;
        emit ReferrerBound(investor, referrer);
    }

    // hooks
    function _isEpochFinalized(uint256 epoch) internal view virtual returns (bool);

    function _transferBaseAssetFrom(address from, uint256 amount) internal virtual;

    function _transferBaseAssetTo(address to, uint256 amount) internal virtual;

    function _transferShares(address from, address to, uint256 shares) internal virtual;
}
