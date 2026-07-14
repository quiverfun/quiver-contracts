// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {Quiver} from "../src/Quiver.sol";
import {QuiverHookStaticFee} from "../src/hooks/QuiverHookStaticFee.sol";
import {IQuiver} from "../src/interfaces/IQuiver.sol";
import {IQuiverHookStaticFee} from "../src/hooks/interfaces/IQuiverHookStaticFee.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {RobinhoodChain} from "./RobinhoodChain.sol";

/// Launches one token through an already-deployed Quiver factory.
/// Reads addresses from deployments/4663.json (written by Deploy.s.sol).
///
///   NAME="My Token" SYMBOL=MINE IMAGE=ipfs://... \
///   forge script script/Launch.s.sol --rpc-url robinhood --account deployer --broadcast
contract Launch is Script {
    using stdJson for string;

    // launch curve config (single-sided ascending ladder).
    // STARTING_TICK sets the implied starting price; at 1B supply this lands
    // FDV around ~$4k (pump.fun-normal), price ~2.2e-9 ETH/token.
    int24 constant TICK_SPACING = 200;
    int24 constant STARTING_TICK = -199_400;
    uint24 constant LP_FEE = 10_000; // 1%

    function run() external {
        require(block.chainid == RobinhoodChain.CHAIN_ID, "wrong chain");

        string memory dep = vm.readFile("./deployments/4663.json");
        address factory = dep.readAddress(".factory");
        address hook = dep.readAddress(".hookStaticFee");
        address locker = dep.readAddress(".lpLocker");
        address mevModule = dep.readAddress(".mevBlockDelay");

        string memory name = vm.envOr("NAME", string("Quiver Test"));
        string memory symbol = vm.envOr("SYMBOL", string("QVRT"));
        string memory image = vm.envOr("IMAGE", string(""));
        address creator = vm.envOr("CREATOR", msg.sender);

        // all fees route to `creator` for v1 (buyback split added later)
        address[] memory admins = new address[](1);
        admins[0] = creator;
        address[] memory recipients = new address[](1);
        recipients[0] = creator;
        uint16[] memory rewardBps = new uint16[](1);
        rewardBps[0] = 10_000;

        int24[] memory tickLower = new int24[](1);
        tickLower[0] = STARTING_TICK;
        int24[] memory tickUpper = new int24[](1);
        tickUpper[0] = (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING;
        uint16[] memory positionBps = new uint16[](1);
        positionBps[0] = 10_000;

        IQuiver.DeploymentConfig memory config = IQuiver.DeploymentConfig({
            tokenConfig: IQuiver.TokenConfig({
                tokenAdmin: creator,
                name: name,
                symbol: symbol,
                salt: bytes32(0),
                image: image,
                metadata: "{}",
                context: '{"interface":"quiver"}',
                originatingChainId: block.chainid
            }),
            poolConfig: IQuiver.PoolConfig({
                hook: hook,
                pairedToken: RobinhoodChain.WETH,
                tickIfToken0IsQuiver: STARTING_TICK,
                tickSpacing: TICK_SPACING,
                poolData: abi.encode(
                    IQuiverHookStaticFee.PoolStaticConfigVars({quiverFee: LP_FEE, pairedFee: LP_FEE})
                )
            }),
            lockerConfig: IQuiver.LockerConfig({
                locker: locker,
                rewardAdmins: admins,
                rewardRecipients: recipients,
                rewardBps: rewardBps,
                tickLower: tickLower,
                tickUpper: tickUpper,
                positionBps: positionBps,
                lockerData: ""
            }),
            mevModuleConfig: IQuiver.MevModuleConfig({mevModule: mevModule, mevModuleData: ""}),
            extensionConfigs: new IQuiver.ExtensionConfig[](0)
        });

        vm.startBroadcast();
        address token = Quiver(factory).deployToken(config);
        vm.stopBroadcast();

        console.log("=== token launched ===");
        console.log("token:  ", token);
        console.log("name:   ", name);
        console.log("symbol: ", symbol);
        console.log("creator:", creator);
        console.log("explorer: https://robinhoodchain.blockscout.com/token/%s", token);
    }
}
