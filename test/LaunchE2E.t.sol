// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {Quiver} from "../src/Quiver.sol";
import {QuiverFeeLocker} from "../src/QuiverFeeLocker.sol";
import {QuiverToken} from "../src/QuiverToken.sol";
import {QuiverHookStaticFee} from "../src/hooks/QuiverHookStaticFee.sol";
import {QuiverLpLockerMultiple} from "../src/lp-lockers/QuiverLpLockerMultiple.sol";
import {QuiverMevBlockDelay} from "../src/mev-modules/QuiverMevBlockDelay.sol";
import {IQuiver} from "../src/interfaces/IQuiver.sol";
import {IQuiverHookStaticFee} from "../src/hooks/interfaces/IQuiverHookStaticFee.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {RobinhoodChain} from "../script/RobinhoodChain.sol";

interface IWETH9 {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
}

/// Full launchpad lifecycle on a Robinhood Chain mainnet fork:
/// deploy stack -> wire -> launch token -> buy -> sell -> fees accrue -> claims.
contract LaunchE2ETest is Test {
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    address owner = makeAddr("owner");
    address team = makeAddr("team");
    address creator = makeAddr("creator");
    address swapper = makeAddr("swapper");

    Quiver factory;
    QuiverFeeLocker feeLocker;
    QuiverHookStaticFee hook;
    QuiverLpLockerMultiple locker;
    QuiverMevBlockDelay mevModule;
    PoolSwapTest swapRouter;

    int24 constant TICK_SPACING = 200;
    int24 constant STARTING_TICK = -230_400; // quiver-style default starting price
    uint24 constant LP_FEE = 10_000; // 1%

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
        mevModule = new QuiverMevBlockDelay(0);
        swapRouter = new PoolSwapTest(IPoolManager(RobinhoodChain.POOL_MANAGER));

        // v4 hooks live at addresses whose low bits encode their permissions
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
        feeLocker.addDepositor(address(locker));
        factory.setTeamFeeRecipient(team);
        factory.setDeprecated(false);
        vm.stopPrank();
    }

    function _launch() internal returns (address token, PoolKey memory poolKey) {
        address[] memory admins = new address[](1);
        admins[0] = creator;
        address[] memory recipients = new address[](1);
        recipients[0] = creator;
        uint16[] memory rewardBps = new uint16[](1);
        rewardBps[0] = 10_000;

        // single-sided ascending ladder: one wide position from start tick to max
        int24[] memory tickLower = new int24[](1);
        tickLower[0] = STARTING_TICK;
        int24[] memory tickUpper = new int24[](1);
        tickUpper[0] = (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING;
        uint16[] memory positionBps = new uint16[](1);
        positionBps[0] = 10_000;

        IQuiver.DeploymentConfig memory config = IQuiver.DeploymentConfig({
            tokenConfig: IQuiver.TokenConfig({
                tokenAdmin: creator,
                name: "Quiver Test",
                symbol: "QVRT",
                salt: bytes32(uint256(1)),
                image: "ipfs://image",
                metadata: "{}",
                context: '{"interface":"quiver"}',
                originatingChainId: block.chainid
            }),
            poolConfig: IQuiver.PoolConfig({
                hook: address(hook),
                pairedToken: WETH,
                tickIfToken0IsQuiver: STARTING_TICK,
                tickSpacing: TICK_SPACING,
                poolData: abi.encode(
                    IQuiverHookStaticFee.PoolStaticConfigVars({quiverFee: LP_FEE, pairedFee: LP_FEE})
                )
            }),
            lockerConfig: IQuiver.LockerConfig({
                locker: address(locker),
                rewardAdmins: admins,
                rewardRecipients: recipients,
                rewardBps: rewardBps,
                tickLower: tickLower,
                tickUpper: tickUpper,
                positionBps: positionBps,
                lockerData: ""
            }),
            mevModuleConfig: IQuiver.MevModuleConfig({
                mevModule: address(mevModule),
                mevModuleData: ""
            }),
            extensionConfigs: new IQuiver.ExtensionConfig[](0)
        });

        token = factory.deployToken(config);

        (Currency c0, Currency c1) = token < WETH
            ? (Currency.wrap(token), Currency.wrap(WETH))
            : (Currency.wrap(WETH), Currency.wrap(token));
        poolKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    function _swapExactIn(PoolKey memory poolKey, bool zeroForOne, uint256 amountIn) internal {
        vm.prank(swapper);
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_launch_trade_fees_e2e() public {
        (address token, PoolKey memory poolKey) = _launch();

        // supply minted in full, admin set, no allocation to deployer
        assertEq(IERC20Min(token).totalSupply(), 100_000_000_000e18, "supply");
        assertEq(IERC20Min(token).balanceOf(creator), 0, "creator gets no free supply");

        // clear the launch MEV window
        vm.roll(block.number + 3);
        vm.warp(block.timestamp + 3 minutes);

        // swapper buys with 1 WETH
        vm.deal(swapper, 10 ether);
        vm.startPrank(swapper);
        IWETH9(WETH).deposit{value: 5 ether}();
        IWETH9(WETH).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        bool wethIsZero = Currency.unwrap(poolKey.currency0) == WETH;
        _swapExactIn(poolKey, wethIsZero, 1 ether);

        uint256 bought = IERC20Min(token).balanceOf(swapper);
        assertGt(bought, 0, "buy should deliver tokens");

        // sell half back (also triggers the hook's deferred protocol-fee sweep:
        // fees banked as ERC-6909 claims during swap N are taken to the factory in swap N+1)
        uint256 wethBefore = IWETH9(WETH).balanceOf(swapper);
        vm.prank(swapper);
        IERC20Min(token).approve(address(swapRouter), type(uint256).max);
        _swapExactIn(poolKey, !wethIsZero, bought / 2);
        assertGt(IWETH9(WETH).balanceOf(swapper), wethBefore, "sell should return WETH");

        // protocol fee swept to the factory in WETH. After buy->sell, the factory
        // holds exactly the buy leg's protocol skim (the sell leg's skim is still
        // banked in the hook until the next swap), and the creator's WETH fees are
        // exactly the buy leg's LP fee — so their ratio must equal the 30% cut.
        assertEq(hook.PROTOCOL_FEE_NUMERATOR(), 300_000, "30% protocol fee constant");
        uint256 factoryWeth = IWETH9(WETH).balanceOf(address(factory));
        assertGt(factoryWeth, 0, "protocol fee accrued");

        // creator LP fees escrowed and claimable
        uint256 creatorFees = feeLocker.availableFees(creator, WETH);
        assertGt(creatorFees, 0, "creator fees accrued");
        assertApproxEqRel(factoryWeth * 10, creatorFees * 3, 0.01e18, "protocol = 30% of LP fee");
        uint256 before = IWETH9(WETH).balanceOf(creator);
        vm.prank(creator);
        feeLocker.claim(creator, WETH);
        assertEq(IWETH9(WETH).balanceOf(creator) - before, creatorFees, "creator claim");

        // team claim of protocol fees
        vm.prank(owner);
        factory.claimTeamFees(WETH);
        assertEq(IWETH9(WETH).balanceOf(team), factoryWeth, "team claim");
    }
}
