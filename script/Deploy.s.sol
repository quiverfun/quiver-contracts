// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {Quiver} from "../src/Quiver.sol";
import {QuiverFeeLocker} from "../src/QuiverFeeLocker.sol";
import {QuiverHookStaticFee} from "../src/hooks/QuiverHookStaticFee.sol";
import {QuiverLpLockerMultiple} from "../src/lp-lockers/QuiverLpLockerMultiple.sol";
import {QuiverMevBlockDelay} from "../src/mev-modules/QuiverMevBlockDelay.sol";
import {QuiverUniv4EthDevBuy} from "../src/extensions/QuiverUniv4EthDevBuy.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {RobinhoodChain} from "./RobinhoodChain.sol";

/// Deploys and wires the Quiver v1 stack on Robinhood Chain (4663).
///
/// Guarded launch: the factory stays `deprecated` (launches disabled) unless
/// ACTIVATE=true. Ownership stays with the broadcaster unless OWNER is set.
///
///   forge script script/Deploy.s.sol --rpc-url robinhood            # dry run
///   make deploy                                                     # broadcast + verify
contract Deploy is Script {
    function run() external {
        require(block.chainid == RobinhoodChain.CHAIN_ID, "wrong chain");

        address deployer = msg.sender;
        address team = vm.envOr("TEAM_FEE_RECIPIENT", deployer);
        address finalOwner = vm.envOr("OWNER", deployer);
        bool activate = vm.envOr("ACTIVATE", false);

        vm.startBroadcast();

        // core
        Quiver factory = new Quiver(deployer);
        QuiverFeeLocker feeLocker = new QuiverFeeLocker(deployer);
        QuiverLpLockerMultiple locker = new QuiverLpLockerMultiple(
            deployer,
            address(factory),
            address(feeLocker),
            RobinhoodChain.POSITION_MANAGER,
            RobinhoodChain.PERMIT2
        );
        QuiverMevBlockDelay mevBlockDelay = new QuiverMevBlockDelay(2);
        QuiverUniv4EthDevBuy devBuy = new QuiverUniv4EthDevBuy(
            address(factory),
            RobinhoodChain.WETH,
            RobinhoodChain.UNIVERSAL_ROUTER,
            RobinhoodChain.PERMIT2
        );

        // hook must land on an address whose low bits encode its permissions;
        // scripts deploy CREATE2 through the canonical deterministic deployer
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        (address minedHook, bytes32 salt) = HookMiner.find(
            CREATE2_FACTORY,
            flags,
            type(QuiverHookStaticFee).creationCode,
            abi.encode(RobinhoodChain.POOL_MANAGER, address(factory), RobinhoodChain.WETH)
        );
        QuiverHookStaticFee hook = new QuiverHookStaticFee{salt: salt}(
            RobinhoodChain.POOL_MANAGER, address(factory), RobinhoodChain.WETH
        );
        require(address(hook) == minedHook, "hook address mismatch");

        // wiring (sequence proven in test/LaunchE2E.t.sol)
        factory.setHook(address(hook), true);
        factory.setLocker(address(locker), address(hook), true);
        factory.setMevModule(address(mevBlockDelay), true);
        factory.setExtension(address(devBuy), true);
        feeLocker.addDepositor(address(locker));
        factory.setTeamFeeRecipient(team);

        if (activate) {
            factory.setDeprecated(false);
        }

        if (finalOwner != deployer) {
            factory.transferOwnership(finalOwner);
            feeLocker.transferOwnership(finalOwner);
            locker.transferOwnership(finalOwner);
        }

        vm.stopBroadcast();

        console.log("=== Quiver v1 on Robinhood Chain (4663) ===");
        console.log("factory:       ", address(factory));
        console.log("feeLocker:     ", address(feeLocker));
        console.log("lpLocker:      ", address(locker));
        console.log("hookStaticFee: ", address(hook));
        console.log("mevBlockDelay: ", address(mevBlockDelay));
        console.log("devBuy:        ", address(devBuy));
        console.log("teamFeeRecipient:", team);
        console.log("owner:         ", finalOwner);
        console.log("launches enabled:", activate);

        string memory json = "deployment";
        vm.serializeAddress(json, "factory", address(factory));
        vm.serializeAddress(json, "feeLocker", address(feeLocker));
        vm.serializeAddress(json, "lpLocker", address(locker));
        vm.serializeAddress(json, "hookStaticFee", address(hook));
        vm.serializeAddress(json, "mevBlockDelay", address(mevBlockDelay));
        vm.serializeAddress(json, "devBuy", address(devBuy));
        vm.serializeAddress(json, "teamFeeRecipient", team);
        vm.serializeAddress(json, "owner", finalOwner);
        vm.serializeUint(json, "chainId", block.chainid);
        string memory out = vm.serializeBool(json, "launchesEnabled", activate);
        vm.writeJson(out, "./deployments/4663.json");
    }
}
