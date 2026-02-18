// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

interface IVaultUser {
    enum ReqStatus {
        Pending,
        Settled,
        Canceled
    }

    struct DepositRequest {
        address investor;
        uint256 amount;
        ReqStatus status;
    }

    struct RedeemRequest {
        address investor;
        uint256 shares;
        ReqStatus status;
    }

    event DepositRequested(uint256 indexed epoch, uint256 indexed index, address indexed investor, uint256 amount);
    event RedeemRequested(uint256 indexed epoch, uint256 indexed index, address indexed investor, uint256 shares);
    event DepositCanceled(uint256 indexed epoch, uint256 indexed index, address indexed investor, uint256 amount);
    event RedeemCanceled(uint256 indexed epoch, uint256 indexed index, address indexed investor, uint256 shares);
    event Claimed(address indexed investor, address indexed to, uint256 amount);
    event ReferrerBound(address indexed investor, address indexed referrer);
    event MinDepositAmountUpdated(uint256 previousValue, uint256 newValue);
    event MinRedeemSharesUpdated(uint256 previousValue, uint256 newValue);

    // write functions
    function requestDeposit(uint256 amount, address referrer) external returns (uint256 epoch, uint256 index);

    function requestRedeem(uint256 shares) external returns (uint256 epoch, uint256 index);

    function cancelDeposit(uint256 epoch, uint256 index) external;

    function cancelRedeem(uint256 epoch, uint256 index) external;

    function claim(address to) external returns (uint256 amount);

    function bindReferrer(address referrer) external;

    function setMinDepositAmount(uint256 newMinDepositAmount) external;

    function setMinRedeemShares(uint256 newMinRedeemShares) external;

    // read functions
    function minDepositAmount() external view returns (uint256);

    function minRedeemShares() external view returns (uint256);

    function claimableAssets(address investor) external view returns (uint256);

    function referrerOf(address investor) external view returns (address);

    function netRequestedDepositAssets(uint256 epoch) external view returns (uint256);

    function netRequestedRedeemShares(uint256 epoch) external view returns (uint256);

    function depositRequestCount(uint256 epoch) external view returns (uint256);

    function redeemRequestCount(uint256 epoch) external view returns (uint256);

    function depositRequestAt(uint256 epoch, uint256 index)
        external
        view
        returns (address investor, uint256 amount, ReqStatus status);

    function redeemRequestAt(uint256 epoch, uint256 index)
        external
        view
        returns (address investor, uint256 shares, ReqStatus status);
}
