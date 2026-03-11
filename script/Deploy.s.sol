// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentEscrowV2Fixed.sol";

contract DeployScript is Script {
    function run() external {
        address arbiter = vm.envAddress("ARBITER_ADDRESS");
        uint256 pk     = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        AgentEscrowV2Fixed escrow = new AgentEscrowV2Fixed(arbiter);
        vm.stopBroadcast();

        console.log("AgentEscrowV2Fixed deployed:", address(escrow));
        console.log("Arbiter:", arbiter);
    }
}
