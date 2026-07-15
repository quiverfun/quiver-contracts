// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {QuiverRushDistributor} from "../src/rewards/QuiverRushDistributor.sol";

import {RobinhoodChain} from "./RobinhoodChain.sol";

/// Deploys the Quiver Rush seasonal rewards distributor.
/// Ownership stays with the broadcaster unless OWNER is set.
///
///   forge script script/DeployRush.s.sol --rpc-url robinhood     # dry run
///   make deploy-rush                                             # broadcast + verify
contract DeployRush is Script {
    function run() external {
        require(block.chainid == RobinhoodChain.CHAIN_ID, "wrong chain");

        address finalOwner = vm.envOr("OWNER", msg.sender);

        vm.startBroadcast();
        QuiverRushDistributor dist =
            new QuiverRushDistributor(finalOwner, RobinhoodChain.WETH);
        vm.stopBroadcast();

        console.log("=== Quiver Rush distributor ===");
        console.log("rushDistributor:", address(dist));
        console.log("owner:          ", finalOwner);

        string memory json = "rush";
        vm.serializeAddress(json, "owner", finalOwner);
        vm.serializeUint(json, "chainId", block.chainid);
        string memory out = vm.serializeAddress(json, "rushDistributor", address(dist));
        vm.writeJson(out, "./deployments/4663-rush.json");
    }
}
