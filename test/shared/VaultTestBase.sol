// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../../src/Vault.sol";
import {VaultFactory} from "../../src/VaultFactory.sol";
import {USDC} from "../mocks/USDC.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

abstract contract VaultTestBase is Test {
    string internal constant FUND_NAME = "Alpha Fund Share";
    string internal constant FUND_SYMBOL = "AFS";

    USDC internal usdc;
    VaultFactory internal factory;
    Vault internal vault;
    UpgradeableBeacon internal beacon;

    address internal beaconOwner = makeAddr("beaconOwner");
    address internal owner = makeAddr("owner");
    address internal manager = makeAddr("manager");
    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal executor = makeAddr("executor");
    address internal outsider = makeAddr("outsider");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function _setUpVaultFixture(
        uint256 initialTimestamp,
        uint256 secondsPerEpoch,
        uint256 initialMinDepositAmount,
        uint256 initialMinRedeemShares
    ) internal {
        vm.warp(initialTimestamp);
        usdc = new USDC();
        factory = _deployFactory(owner);
        vault = Vault(
            _createFund(
                factory,
                owner,
                address(usdc),
                manager,
                admin,
                operator,
                executor,
                secondsPerEpoch,
                initialMinDepositAmount,
                initialMinRedeemShares
            )
        );
    }

    function _deployFactory(address initialOwner) internal returns (VaultFactory localFactory) {
        Vault implementation = new Vault();
        beacon = new UpgradeableBeacon(address(implementation), beaconOwner);
        localFactory = _deployFactoryProxy(address(beacon), initialOwner);
    }

    function _deployFactoryProxy(address beaconAddress, address initialOwner) internal returns (VaultFactory) {
        VaultFactory implementation = new VaultFactory();
        bytes memory initData = abi.encodeCall(VaultFactory.initialize, (beaconAddress, initialOwner));
        return VaultFactory(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _createFund(
        VaultFactory targetFactory,
        address caller,
        address baseAsset,
        address _manager,
        address _admin,
        address _operator,
        address _executor,
        uint256 _secondsPerEpoch,
        uint256 initialMinDepositAmount,
        uint256 initialMinRedeemShares
    ) internal returns (address vaultProxy) {
        vm.prank(caller);
        vaultProxy = targetFactory.createFund(
            FUND_NAME,
            FUND_SYMBOL,
            baseAsset,
            _manager,
            _admin,
            _operator,
            _executor,
            _secondsPerEpoch,
            initialMinDepositAmount,
            initialMinRedeemShares
        );
    }
}
