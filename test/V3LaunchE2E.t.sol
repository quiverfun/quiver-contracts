// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {QuiverV3} from "../src/v3/QuiverV3.sol";
import {QuiverLpLockerV3} from "../src/v3/QuiverLpLockerV3.sol";
import {ISwapRouter02, IUniswapV3Pool} from "../src/v3/interfaces/IUniswapV3.sol";
import {IQuiver} from "../src/interfaces/IQuiver.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {RobinhoodChain} from "../script/RobinhoodChain.sol";

interface IWETH9Test {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
}

interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (
            uint256 amountOut,
            uint160 sqrtPriceX96After,
            uint32 initializedTicksCrossed,
            uint256 gasEstimate
        );
}

/// Quiver v3 lifecycle on a Robinhood Chain mainnet fork — the whole point:
/// every trade goes through the STANDARD SwapRouter02 that terminal
/// simulators (GMGN etc.) use, and a first buyer can fully round-trip.
contract V3LaunchE2ETest is Test {
    address constant WETH = RobinhoodChain.WETH;

    address owner = makeAddr("owner");
    address team = makeAddr("team");
    address creator = makeAddr("creator");
    address swapper = makeAddr("swapper");

    QuiverV3 factory;
    QuiverLpLockerV3 locker;
    ISwapRouter02 router = ISwapRouter02(RobinhoodChain.V3_SWAP_ROUTER_02);

    int24 constant TICK_SPACING = 200;
    int24 constant STARTING_TICK = -204_400; // ~$2.5k implied FDV at 1B supply
    uint16 constant PROTOCOL_BPS = 5000; // launch config: 50/50 creator/protocol

    function setUp() public {
        vm.createSelectFork("robinhood");

        locker = new QuiverLpLockerV3(owner);
        factory = new QuiverV3(
            owner,
            RobinhoodChain.V3_FACTORY,
            RobinhoodChain.V3_SWAP_ROUTER_02,
            WETH,
            address(locker),
            PROTOCOL_BPS
        );

        vm.startPrank(owner);
        locker.setFactory(address(factory));
        factory.setTeamFeeRecipient(team);
        factory.setDeprecated(false);
        vm.stopPrank();
    }

    function _launch(uint256 devBuyEth) internal returns (address token) {
        // single-sided ascending ladder: one wide range from start tick to max
        QuiverV3.PoolPosition[] memory positions = new QuiverV3.PoolPosition[](1);
        positions[0] = QuiverV3.PoolPosition({
            tickLower: STARTING_TICK,
            tickUpper: (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING,
            bps: 10_000
        });

        token = factory.deployToken{value: devBuyEth}(
            IQuiver.TokenConfig({
                tokenAdmin: creator,
                name: "Quiver V3 Test",
                symbol: "QV3T",
                salt: bytes32(uint256(42)),
                image: "ipfs://image",
                metadata: "{}",
                context: '{"interface":"quiver"}',
                originatingChainId: block.chainid
            }),
            STARTING_TICK,
            positions,
            creator
        );
    }

    function _buy(address who, address token, uint256 ethIn) internal returns (uint256 out) {
        vm.startPrank(who);
        IWETH9Test(WETH).deposit{value: ethIn}();
        IWETH9Test(WETH).approve(address(router), ethIn);
        out = router.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: token,
                fee: factory.POOL_FEE(),
                recipient: who,
                amountIn: ethIn,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
    }

    function _sell(address who, address token, uint256 tokenIn) internal returns (uint256 out) {
        vm.startPrank(who);
        IERC20Min(token).approve(address(router), tokenIn);
        out = router.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: WETH,
                fee: factory.POOL_FEE(),
                recipient: who,
                amountIn: tokenIn,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
    }

    /// The friend's question, as an executable proof: with ZERO initial buy,
    /// the pool needs no seed ETH, and the very first user can buy AND fully
    /// sell back through the standard router, recovering ~98% (2 x 1% fee).
    function test_firstBuyer_fullRoundTrip_standardRouter() public {
        address token = _launch(0); // zero dev buy

        // full supply is in the pool as single-sided liquidity; nobody holds any
        assertEq(IERC20Min(token).totalSupply(), 1_000_000_000e18, "supply");
        assertEq(IERC20Min(token).balanceOf(creator), 0, "creator starts with nothing");

        vm.deal(swapper, 2 ether);
        uint256 bought = _buy(swapper, token, 1 ether);
        assertGt(bought, 0, "first buy fills against the token-only ladder");

        uint256 wethBefore = IWETH9Test(WETH).balanceOf(swapper);
        uint256 returned = _sell(swapper, token, bought);
        uint256 wethAfter = IWETH9Test(WETH).balanceOf(swapper);

        assertEq(wethAfter - wethBefore, returned, "router pays WETH out");
        // round trip through two 1% fee legs: expect ~98%, assert > 97%
        assertGt(returned, 0.97 ether, "first buyer can fully exit");
        assertLt(returned, 1 ether, "fees were charged, not skipped");
        assertEq(IERC20Min(token).balanceOf(swapper), 0, "sold everything");
    }

    /// QuoterV2 must quote both directions — this is what scanner sims exercise.
    function test_quoterV2_quotesBothDirections() public {
        address token = _launch(0);

        IQuoterV2 quoter = IQuoterV2(RobinhoodChain.V3_QUOTER_V2);
        (uint256 tokensOut,,,) = quoter.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: token,
                amountIn: 0.1 ether,
                fee: factory.POOL_FEE(),
                sqrtPriceLimitX96: 0
            })
        );
        assertGt(tokensOut, 0, "buy quote");

        // buy first so there is WETH-side liquidity for the sell quote
        vm.deal(swapper, 1 ether);
        uint256 bought = _buy(swapper, token, 0.5 ether);

        (uint256 wethOut,,,) = quoter.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: token,
                tokenOut: WETH,
                amountIn: bought,
                fee: factory.POOL_FEE(),
                sqrtPriceLimitX96: 0
            })
        );
        assertGt(wethOut, 0, "sell quote");
    }

    /// Dev buy in the launch tx: creator receives tokens, chart baseline intact.
    function test_devBuy_atLaunch() public {
        vm.deal(address(this), 0.05 ether);
        address token = _launch(0.05 ether);

        uint256 creatorTokens = IERC20Min(token).balanceOf(creator);
        assertGt(creatorTokens, 0, "dev buy delivered to token admin");

        // creator can immediately sell through the standard router
        uint256 returned = _sell(creator, token, creatorTokens);
        assertGt(returned, 0.04 ether, "dev buy is fully exitable too");
    }

    /// Fees accrue to the locked positions and split creator/protocol.
    function test_feeCollection_andSplit() public {
        address token = _launch(0);

        vm.deal(swapper, 12 ether);
        uint256 bought = _buy(swapper, token, 10 ether);
        _sell(swapper, token, bought / 2);

        uint256 creatorWethBefore = IWETH9Test(WETH).balanceOf(creator);
        uint256 teamWethBefore = IWETH9Test(WETH).balanceOf(team);

        locker.collectRewards(token);

        uint256 creatorGot = IWETH9Test(WETH).balanceOf(creator) - creatorWethBefore;
        uint256 teamGot = IWETH9Test(WETH).balanceOf(team) - teamWethBefore;

        assertGt(creatorGot, 0, "creator fees");
        assertGt(teamGot, 0, "protocol fees");
        // 50/50 split with the last-recipient-remainder pattern: near-equal
        assertApproxEqRel(creatorGot, teamGot, 0.01e18, "50/50 split");

        // ~1% of 10 ETH buy volume + ~1% of the sell leg, in WETH terms
        assertGt(creatorGot + teamGot, 0.09 ether, "fee magnitude sanity");
    }

    /// The locker owns the liquidity as raw pool positions (no NFT — reads as
    /// burnt to LP scanners) and has no code path to withdraw it.
    function test_lockerHoldsPositionsForever() public {
        address token = _launch(0);
        (address pool, QuiverLpLockerV3.PositionRange[] memory ranges,,) =
            locker.tokenRewards(token);
        assertEq(ranges.length, 1, "one ladder position");

        // the raw position in pool state is owned by the locker and has liquidity
        bytes32 key = keccak256(
            abi.encodePacked(address(locker), ranges[0].tickLower, ranges[0].tickUpper)
        );
        (uint128 liquidity,,,,) = IUniswapV3Pool(pool).positions(key);
        assertGt(liquidity, 0, "locker owns the pool liquidity");

        // and no token supply sits anywhere claimable: factory and locker are empty
        assertEq(IERC20Min(token).balanceOf(address(factory)), 0, "factory holds nothing");
        assertEq(IERC20Min(token).balanceOf(address(locker)), 0, "locker holds nothing");
    }

    receive() external payable {}
}
