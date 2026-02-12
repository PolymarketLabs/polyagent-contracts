// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {VaultFactory} from "../src/VaultFactory.sol";

contract DeployVaultFactoryScript is Script {
    uint256 pk = vm.envUint("PRIVATE_KEY");
    address beaconAddress = vm.envAddress("BEACON");

    function run() external {
        vm.startBroadcast(pk);

        address owner = msg.sender;
        VaultFactory implementation = new VaultFactory();
        bytes memory initData = abi.encodeCall(VaultFactory.initialize, (beaconAddress, owner));
        VaultFactory factory = VaultFactory(address(new ERC1967Proxy(address(implementation), initData)));

        vm.stopBroadcast();

        console2.log("beacon:", beaconAddress);
        console2.log("factory implementation:", address(implementation));
        console2.log("factory proxy:", address(factory));
    }
}
