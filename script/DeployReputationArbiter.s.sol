// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/ReputationArbiter.sol";

contract DeployReputationArbiter is Script {
    function run() external {
        // AgentEscrowV4 deployed at this address on Polygon
        address escrowV4 = 0xf8a7e6b5Decfe1b6F57e3D16d8005BCa5Be88B6A;

        vm.startBroadcast();
        ReputationArbiter arbiter = new ReputationArbiter(escrowV4);
        vm.stopBroadcast();

        console.log("ReputationArbiter deployed at:", address(arbiter));
        console.log("Reputation source (EscrowV4):", escrowV4);
    }
}
