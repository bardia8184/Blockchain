// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MultiSigVault} from "../src/MultiSigVault.sol";

contract DeployMultiSig is Script {
    function run() external {
        address owner1 = vm.envAddress("OWNER1");
        address owner2 = vm.envAddress("OWNER2");
        address owner3 = vm.envAddress("OWNER3");

        address[] memory owners = new address[](3);
        owners[0] = owner1;
        owners[1] = owner2;
        owners[2] = owner3;

        uint256 required = 2; // 2-of-3

        vm.startBroadcast();
        MultiSigVault vault = new MultiSigVault(owners, required);
        vm.stopBroadcast();

        console.log("MultiSigVault:", address(vault));
        console.log("Owner1:", owner1);
        console.log("Owner2:", owner2);
        console.log("Owner3:", owner3);
    }
}
