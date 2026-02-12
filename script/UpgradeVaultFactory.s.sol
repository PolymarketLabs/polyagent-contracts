// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {VaultFactoryV2} from "../src/VaultFactoryV2.sol";

contract UpgradeFactoryScript is Script {
    uint256 pk = vm.envUint("PRIVATE_KEY");
    address factoryProxy = vm.envAddress("FACTORY_PROXY");

    function run() external {
        vm.startBroadcast(pk);

        // 1) 部署新的 Factory 实现
        VaultFactoryV2 implementationV2 = new VaultFactoryV2();

        // 2) 通过 UUPS 升级 proxy，并调用 initializeV2 推进初始化版本号
        VaultFactory factory = VaultFactory(factoryProxy);
        bytes memory initV2Data = abi.encodeCall(VaultFactoryV2.initializeV2, ());
        factory.upgradeToAndCall(address(implementationV2), initV2Data);

        vm.stopBroadcast();

        console2.log("factory proxy:", address(factory));
        console2.log("new factory implementation:", address(implementationV2));
    }
}
