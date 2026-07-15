// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {Quiver} from "../src/Quiver.sol";
import {QuiverFeeLocker} from "../src/QuiverFeeLocker.sol";
import {QuiverHookStaticFee} from "../src/hooks/QuiverHookStaticFee.sol";
import {QuiverLpLockerMultiple} from "../src/lp-lockers/QuiverLpLockerMultiple.sol";
import {QuiverMevBlockDelay} from "../src/mev-modules/QuiverMevBlockDelay.sol";
import {QuiverUniv4EthDevBuy} from "../src/extensions/QuiverUniv4EthDevBuy.sol";
import {IQuiver} from "../src/interfaces/IQuiver.sol";
import {IQuiverUniv4EthDevBuy} from "../src/extensions/interfaces/IQuiverUniv4EthDevBuy.sol";
import {IQuiverHookStaticFee} from "../src/hooks/interfaces/IQuiverHookStaticFee.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {RobinhoodChain} from "../script/RobinhoodChain.sol";

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// Initial-buy (dev buy) lifecycle on a Robinhood Chain mainnet fork.
///
/// The chain's deployed Universal Router is a modified build whose
/// ExactInputSingleParams carries an extra `minHopPriceX36` field; an
/// extension that encodes the standard v4-periphery struct reverts against
/// it. These tests pin both sides: the fixed encoding works end-to-end, and
/// the originally deployed extension (standard encoding) reverts.
contract DevBuyE2ETest is Test {
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    // live deployment (deployments/4663.json) — the factory the app talks to
    address constant LIVE_FACTORY = 0x1FdCc42e982A9555D1134FdA56Ac739F534642c4;
    address constant LIVE_HOOK = 0x0998ECDd40500Ae7B38b9fFc39dFeaa4FFB528CC;
    address constant LIVE_LOCKER = 0xb35C178683fBabf3Ab7c8d79853717254C2248ec;
    address constant LIVE_MEV_MODULE = 0x11c72d9e1A6A6ca63D954592b8fc477C2888Ee9C;
    // fixed-encoding build, live since the RedeployDevBuy broadcast
    address constant LIVE_DEV_BUY = 0xE4b492bF4b5bB898741a961F15b9813c40d63C4A;
    // original build (standard router encoding — reverts), disabled on the factory
    address constant OLD_DEV_BUY = 0xCD25da20D400BE5c5b3c3830392342EC7418aAfB;

    address owner = makeAddr("owner");
    address team = makeAddr("team");
    address creator = makeAddr("creator");

    Quiver factory;
    QuiverFeeLocker feeLocker;
    QuiverHookStaticFee hook;
    QuiverLpLockerMultiple locker;
    QuiverMevBlockDelay mevModule;
    QuiverUniv4EthDevBuy devBuy;

    int24 constant TICK_SPACING = 200;
    int24 constant STARTING_TICK = -199_400;
    uint24 constant LP_FEE = 10_000;

    function setUp() public {
        vm.createSelectFork("robinhood");

        factory = new Quiver(owner);
        feeLocker = new QuiverFeeLocker(owner);
        locker = new QuiverLpLockerMultiple(
            owner,
            address(factory),
            address(feeLocker),
            RobinhoodChain.POSITION_MANAGER,
            RobinhoodChain.PERMIT2
        );
        mevModule = new QuiverMevBlockDelay(2);
        devBuy = new QuiverUniv4EthDevBuy(
            address(factory),
            WETH,
            RobinhoodChain.UNIVERSAL_ROUTER,
            RobinhoodChain.PERMIT2
        );

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        (, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(QuiverHookStaticFee).creationCode,
            abi.encode(RobinhoodChain.POOL_MANAGER, address(factory), WETH)
        );
        hook = new QuiverHookStaticFee{salt: salt}(
            RobinhoodChain.POOL_MANAGER, address(factory), WETH
        );

        vm.startPrank(owner);
        factory.setHook(address(hook), true);
        factory.setLocker(address(locker), address(hook), true);
        factory.setMevModule(address(mevModule), true);
        factory.setExtension(address(devBuy), true);
        feeLocker.addDepositor(address(locker));
        factory.setTeamFeeRecipient(team);
        factory.setDeprecated(false);
        vm.stopPrank();
    }

    function _config(
        address hook_,
        address locker_,
        address mevModule_,
        address devBuy_,
        uint256 devBuyEth,
        bytes32 salt
    ) internal view returns (IQuiver.DeploymentConfig memory) {
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

        IQuiver.ExtensionConfig[] memory extensions = new IQuiver.ExtensionConfig[](1);
        extensions[0] = IQuiver.ExtensionConfig({
            extension: devBuy_,
            msgValue: devBuyEth,
            extensionBps: 0,
            extensionData: abi.encode(
                IQuiverUniv4EthDevBuy.Univ4EthDevBuyExtensionData({
                    // paired token IS WETH, so the hop pool key is unused
                    pairedTokenPoolKey: PoolKey({
                        currency0: Currency.wrap(address(0)),
                        currency1: Currency.wrap(address(0)),
                        fee: 0,
                        tickSpacing: 0,
                        hooks: IHooks(address(0))
                    }),
                    pairedTokenAmountOutMinimum: 0,
                    recipient: creator
                })
            )
        });

        return IQuiver.DeploymentConfig({
            tokenConfig: IQuiver.TokenConfig({
                tokenAdmin: creator,
                name: "Quiver DevBuy Test",
                symbol: "QVRD",
                salt: salt,
                image: "ipfs://image",
                metadata: '{"description":"devbuy e2e"}',
                context: '{"interface":"quiver"}',
                originatingChainId: block.chainid
            }),
            poolConfig: IQuiver.PoolConfig({
                hook: hook_,
                pairedToken: WETH,
                tickIfToken0IsQuiver: STARTING_TICK,
                tickSpacing: TICK_SPACING,
                poolData: abi.encode(
                    IQuiverHookStaticFee.PoolStaticConfigVars({quiverFee: LP_FEE, pairedFee: LP_FEE})
                )
            }),
            lockerConfig: IQuiver.LockerConfig({
                locker: locker_,
                rewardAdmins: admins,
                rewardRecipients: recipients,
                rewardBps: rewardBps,
                tickLower: tickLower,
                tickUpper: tickUpper,
                positionBps: positionBps,
                lockerData: ""
            }),
            mevModuleConfig: IQuiver.MevModuleConfig({
                mevModule: mevModule_,
                mevModuleData: ""
            }),
            extensionConfigs: extensions
        });
    }

    /// Fixed encoding: launch with a 0.5 ETH initial buy — the creator must
    /// receive tokens in the launch tx, before the MEV block delay engages.
    function test_devBuy_initialBuy_e2e() public {
        vm.deal(creator, 1 ether);

        IQuiver.DeploymentConfig memory config = _config(
            address(hook),
            address(locker),
            address(mevModule),
            address(devBuy),
            0.5 ether,
            bytes32(uint256(0xD1))
        );

        vm.prank(creator);
        address token = factory.deployToken{value: 0.5 ether}(config);

        assertEq(IERC20Min(token).totalSupply(), 1_000_000_000e18, "full supply minted");
        uint256 bought = IERC20Min(token).balanceOf(creator);
        assertGt(bought, 0, "initial buy should deliver tokens to creator");
        // 0.5 ETH into a ~$4k-FDV single-sided ladder buys a large chunk of
        // supply; sanity-bound it so a mis-scaled ladder can't pass silently
        assertGt(bought, 10_000_000e18, "unexpectedly small initial buy");
        assertLt(bought, 1_000_000_000e18, "buy cannot exceed supply");
        assertEq(address(devBuy).balance, 0, "no ETH stranded in extension");
        assertEq(
            IERC20Min(token).balanceOf(address(devBuy)), 0, "no tokens stranded in extension"
        );
    }

    /// Factory rejects a devBuy config whose msgValue disagrees with the ETH
    /// actually sent (sum-of-extensions check).
    function test_devBuy_msgValueMismatch_reverts() public {
        vm.deal(creator, 1 ether);
        IQuiver.DeploymentConfig memory config = _config(
            address(hook),
            address(locker),
            address(mevModule),
            address(devBuy),
            0.5 ether,
            bytes32(uint256(0xD2))
        );
        vm.prank(creator);
        vm.expectRevert(IQuiver.ExtensionMsgValueMismatch.selector);
        factory.deployToken{value: 0.4 ether}(config);
    }

    /// The production path end-to-end: live factory, live modules, live
    /// (redeployed) devBuy — exactly the contracts the web app hits.
    function test_liveRedeployedDevBuy_initialBuy_works() public {
        vm.deal(creator, 1 ether);

        IQuiver.DeploymentConfig memory config = _config(
            LIVE_HOOK,
            LIVE_LOCKER,
            LIVE_MEV_MODULE,
            LIVE_DEV_BUY,
            0.5 ether,
            bytes32(uint256(0xD3))
        );

        vm.prank(creator);
        address token = Quiver(payable(LIVE_FACTORY)).deployToken{value: 0.5 ether}(config);

        assertGt(IERC20Min(token).balanceOf(creator), 0, "live initial buy delivers tokens");
        assertEq(LIVE_DEV_BUY.balance, 0, "no ETH stranded in live extension");
    }

    /// The original extension (standard v4-periphery encoding, which reverts
    /// against the chain's modified Universal Router) is disabled on the
    /// factory — launches referencing it must be rejected outright.
    function test_oldDevBuy_disabledOnFactory() public {
        vm.deal(creator, 1 ether);

        IQuiver.DeploymentConfig memory config = _config(
            LIVE_HOOK,
            LIVE_LOCKER,
            LIVE_MEV_MODULE,
            OLD_DEV_BUY,
            0.5 ether,
            bytes32(uint256(0xD4))
        );

        vm.prank(creator);
        vm.expectRevert(IQuiver.ExtensionNotEnabled.selector);
        Quiver(payable(LIVE_FACTORY)).deployToken{value: 0.5 ether}(config);
    }
}
