// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Vault} from "../src/Vault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";

contract DeployBeaconScript is Script {
    uint256 pk = vm.envUint("PRIVATE_KEY");

    function run() external {
        vm.startBroadcast(pk);

        // 1) 部署 UpgradeableBeacon（内部会部署实现合约），并设置 owner
        address owner = msg.sender;
        Vault implementation = new Vault();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(implementation), owner);

        // 2) 部署 VaultFactory 实现并初始化 UUPS 代理
        VaultFactory implementationFactory = new VaultFactory();
        bytes memory initData = abi.encodeCall(VaultFactory.initialize, (address(beacon), owner));
        VaultFactory factory = VaultFactory(address(new ERC1967Proxy(address(implementationFactory), initData)));

        vm.stopBroadcast();

        console2.log("beacon:", address(beacon));
        console2.log("factory implementation:", address(implementationFactory));
        console2.log("factory :", address(factory));
    }
}
