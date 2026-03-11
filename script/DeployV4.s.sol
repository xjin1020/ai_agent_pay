// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "forge-std/Script.sol";
import "../src/AgentEscrowV4.sol";
contract DeployV4 is Script {
    function run() external {
        address arbiter      = vm.envAddress("ARBITER_ADDRESS");
        address feeCollector = vm.envAddress("ARBITER_ADDRESS"); // same for now
        uint256 pk           = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        AgentEscrowV4 escrow = new AgentEscrowV4(arbiter, feeCollector);
        vm.stopBroadcast();
        console.log("AgentEscrowV4 deployed:", address(escrow));
    }
}
