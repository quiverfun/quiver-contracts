// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {Quiver} from "../src/Quiver.sol";
import {QuiverUniv4EthDevBuy} from "../src/extensions/QuiverUniv4EthDevBuy.sol";

import {RobinhoodChain} from "./RobinhoodChain.sol";

/// Replaces the devBuy extension on the live factory.
///
/// The original QuiverUniv4EthDevBuy encoded the standard v4-periphery
/// ExactInputSingleParams; Robinhood Chain's modified Universal Router
/// expects an extra `minHopPriceX36` field, so every dev buy through the old
/// extension reverted (pinned by test/DevBuyE2E.t.sol). Deploys the fixed
/// build, enables it, and disables the old one.
///
/// Must be broadcast by the factory owner. Note: like Deploy.s.sol, a dry
/// run also rewrites deployments/4663.json (with the simulated address).
///
///   make redeploy-devbuy-dry    # simulate against live chain state
///   make redeploy-devbuy        # broadcast + verify
contract RedeployDevBuy is Script {
    function run() external {
        require(block.chainid == RobinhoodChain.CHAIN_ID, "wrong chain");

        string memory json = vm.readFile("./deployments/4663.json");
        Quiver factory = Quiver(payable(vm.parseJsonAddress(json, ".factory")));
        address oldDevBuy = vm.parseJsonAddress(json, ".devBuy");

        vm.startBroadcast();

        QuiverUniv4EthDevBuy devBuy = new QuiverUniv4EthDevBuy(
            address(factory),
            RobinhoodChain.WETH,
            RobinhoodChain.UNIVERSAL_ROUTER,
            RobinhoodChain.PERMIT2
        );
        factory.setExtension(address(devBuy), true);
        factory.setExtension(oldDevBuy, false);

        vm.stopBroadcast();

        console.log("=== devBuy replaced on Robinhood Chain (4663) ===");
        console.log("factory:      ", address(factory));
        console.log("old devBuy:   ", oldDevBuy, "(disabled)");
        console.log("new devBuy:   ", address(devBuy));

        vm.writeJson(vm.toString(address(devBuy)), "./deployments/4663.json", ".devBuy");
    }
}
