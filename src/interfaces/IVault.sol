// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

interface IVault {
    event BaseAssetTransferredToExecutor(address indexed operator, address indexed executor, uint256 amount);

    // write functions
    /// @notice Initializes Vault core configuration and role bindings.
    /// @param tokenName Share token name.
    /// @param tokenSymbol Share token symbol.
    /// @param _baseAsset Base asset address (for example, USDC).
    /// @param _admin Default admin address.
    /// @param _operator Operator role address.
    /// @param _executor Executor wallet address.
    /// @param _secondsPerEpoch Settlement epoch length in seconds.
    /// @param _initialMinDepositAmount Initial minimum deposit amount.
    /// @param _initialMinRedeemShares Initial minimum redeem shares.
    function initialize(
        string memory tokenName,
        string memory tokenSymbol,
        address _baseAsset,
        address _admin,
        address _operator,
        address _executor,
        uint256 _secondsPerEpoch,
        uint256 _initialMinDepositAmount,
        uint256 _initialMinRedeemShares
    ) external;

    /// @notice Transfers base asset from Vault to the configured executor.
    /// @param amount Amount of base asset to transfer.
    function transferBaseAssetToExecutor(uint256 amount) external;

    // read functions
    /// @notice Returns the base asset address.
    function baseAsset() external view returns (address);

    /// @notice Returns the initialized version (initializer/reinitializer).
    function initializedVersion() external view returns (uint64);
}
