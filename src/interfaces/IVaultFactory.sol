// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

interface IVaultFactory {
    event FundCreated(
        address indexed vault, address indexed baseAsset, address indexed manager, uint256 createdAt, uint256 fundId
    );

    /// @notice Initializes the factory (callable only once).
    /// @param beacon Vault beacon address.
    /// @param initialOwner Factory owner address.
    function initialize(address beacon, address initialOwner) external;

    /// @notice Creates and initializes a new fund Vault (owner only).
    /// @param tokenName Share token name.
    /// @param tokenSymbol Share token symbol.
    /// @param baseAsset Base asset address.
    /// @param manager Fund manager address.
    /// @param admin Vault admin address.
    /// @param operator Vault operator address.
    /// @param executor Vault executor wallet address.
    /// @param secondsPerEpoch Settlement epoch length in seconds.
    /// @param initialMinDepositAmount Initial minimum deposit amount.
    /// @param initialMinRedeemShares Initial minimum redeem shares.
    /// @return vault Newly created Vault proxy address.
    function createFund(
        string memory tokenName,
        string memory tokenSymbol,
        address baseAsset,
        address manager,
        address admin,
        address operator,
        address executor,
        uint256 secondsPerEpoch,
        uint256 initialMinDepositAmount,
        uint256 initialMinRedeemShares
    ) external returns (address vault);

    /// @notice Returns the total number of created funds.
    function totalFunds() external view returns (uint256);

    /// @notice Returns the initialized version (initializer/reinitializer).
    function initializedVersion() external view returns (uint64);
}
