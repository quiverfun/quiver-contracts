// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {QuiverV3} from "../src/v3/QuiverV3.sol";
import {QuiverLpLockerV3} from "../src/v3/QuiverLpLockerV3.sol";

import {RobinhoodChain} from "./RobinhoodChain.sol";

/// Deploys and wires the Quiver v3 stack (plain Uniswap v3 pools — no hooks,
/// no MEV module, standard router) on Robinhood Chain (4663).
///
/// Guarded launch: the factory stays `deprecated` (launches disabled) unless
/// ACTIVATE=true. Ownership stays with the broadcaster unless OWNER is set.
///
///   forge script script/DeployV3.s.sol --rpc-url robinhood          # dry run
///   make deploy-v3                                                  # broadcast + verify
contract DeployV3 is Script {
    uint16 constant PROTOCOL_BPS = 5000; // launch fee policy: 50/50 creator/protocol

    function run() external {
        require(block.chainid == RobinhoodChain.CHAIN_ID, "wrong chain");

        address deployer = msg.sender;
        address team = vm.envOr("TEAM_FEE_RECIPIENT", deployer);
        address finalOwner = vm.envOr("OWNER", deployer);
        bool activate = vm.envOr("ACTIVATE", false);

        vm.startBroadcast();

        QuiverLpLockerV3 locker = new QuiverLpLockerV3(deployer);
        QuiverV3 factory = new QuiverV3(
            deployer,
            RobinhoodChain.V3_FACTORY,
            RobinhoodChain.V3_SWAP_ROUTER_02,
            RobinhoodChain.WETH,
            address(locker),
            PROTOCOL_BPS
        );

        // wiring (sequence proven in test/V3LaunchE2E.t.sol)
        locker.setFactory(address(factory));
        factory.setTeamFeeRecipient(team);

        if (activate) {
            factory.setDeprecated(false);
        }

        if (finalOwner != deployer) {
            factory.transferOwnership(finalOwner);
            locker.transferOwnership(finalOwner);
        }

        vm.stopBroadcast();

        console.log("=== Quiver v3 on Robinhood Chain (4663) ===");
        console.log("factoryV3:     ", address(factory));
        console.log("lpLockerV3:    ", address(locker));
        console.log("teamFeeRecipient:", team);
        console.log("owner:         ", finalOwner);
        console.log("launches enabled:", activate);

        string memory json = "deploymentV3";
        vm.serializeAddress(json, "factoryV3", address(factory));
        vm.serializeAddress(json, "lpLockerV3", address(locker));
        vm.serializeAddress(json, "teamFeeRecipient", team);
        vm.serializeAddress(json, "owner", finalOwner);
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeUint(json, "protocolBps", PROTOCOL_BPS);
        string memory out = vm.serializeBool(json, "launchesEnabled", activate);
        vm.writeJson(out, "./deployments/4663-v3.json");
    }
}
