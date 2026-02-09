// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {VaultV2} from "../src/VaultV2.sol";

contract UpgradeBeaconScript is Script {
    uint256 pk = vm.envUint("PRIVATE_KEY");
    address beaconAddress = vm.envAddress("BEACON");

    function run() external {
        vm.startBroadcast(pk);

        // 部署新实现并升级 beacon 指向，需广播账户为 beacon owner。
        VaultV2 implementationV2 = new VaultV2();
        UpgradeableBeacon beacon = UpgradeableBeacon(beaconAddress);
        beacon.upgradeTo(address(implementationV2));

        vm.stopBroadcast();
        console2.log("beacon:", address(beacon));
        console2.log("new implementation:", address(implementationV2));
    }
}
