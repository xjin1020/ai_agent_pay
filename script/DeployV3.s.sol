// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "forge-std/Script.sol";
import "../src/AgentEscrowV3.sol";
contract DeployV3 is Script {
    function run() external {
        address arbiter = vm.envAddress("ARBITER_ADDRESS");
        uint256 pk      = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        AgentEscrowV3 escrow = new AgentEscrowV3(arbiter);
        vm.stopBroadcast();
        console.log("AgentEscrowV3 deployed:", address(escrow));
    }
}
