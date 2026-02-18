// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Vault} from "../src/Vault.sol";

contract DeployVaultScript is Script {
    uint256 pk = vm.envUint("PRIVATE_KEY");

    function run() external {
        vm.startBroadcast(pk);

        address owner = vm.addr(pk);
        // 部署 Vault 实现合约
        Vault implementation = new Vault();
        // 部署 UpgradeableBeacon，并设置 owner
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(implementation), owner);

        vm.stopBroadcast();

        console2.log("beacon:", address(beacon));
        console2.log("vault implementation:", address(implementation));
    }
}
