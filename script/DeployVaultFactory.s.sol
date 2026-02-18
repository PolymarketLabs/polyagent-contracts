// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {VaultFactory} from "../src/VaultFactory.sol";

contract DeployVaultFactoryScript is Script {
    error InvalidBeaconAddress();
    error InvalidBeaconImplementation();

    uint256 pk = vm.envUint("PRIVATE_KEY");
    address beaconAddress = vm.envAddress("BEACON");

    function run() external {
        _validateBeacon(beaconAddress);

        vm.startBroadcast(pk);

        address owner = vm.addr(pk);
        VaultFactory factoryImplementation = new VaultFactory();
        bytes memory initData = abi.encodeCall(VaultFactory.initialize, (beaconAddress, owner));
        VaultFactory factory = VaultFactory(address(new ERC1967Proxy(address(factoryImplementation), initData)));

        vm.stopBroadcast();

        console2.log("beacon:", beaconAddress);
        console2.log("factory implementation:", address(factoryImplementation));
        console2.log("factory proxy:", address(factory));
    }

    function _validateBeacon(address beacon) internal view {
        if (beacon == address(0) || beacon.code.length == 0) {
            revert InvalidBeaconAddress();
        }

        try UpgradeableBeacon(beacon).implementation() returns (address beaconImplementation) {
            if (beaconImplementation == address(0)) {
                revert InvalidBeaconImplementation();
            }
        } catch {
            revert InvalidBeaconAddress();
        }
    }
}
