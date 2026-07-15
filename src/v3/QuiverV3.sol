// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {QuiverDeployer} from "../utils/QuiverDeployer.sol";
import {OwnerAdmins} from "../utils/OwnerAdmins.sol";
import {IQuiver} from "../interfaces/IQuiver.sol";
import {QuiverLpLockerV3} from "./QuiverLpLockerV3.sol";
import {ISwapRouter02, IUniswapV3Factory, IUniswapV3Pool, IWETH9} from "./interfaces/IUniswapV3.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title QuiverV3 — token launcher on plain Uniswap v3
/// @notice Launches a fixed-supply token straight into a hookless Uniswap v3
///         pool (1% fee tier) seeded with single-sided token liquidity laddered
///         above the starting tick. No bonding curve, no graduation, no hooks —
///         tradeable through the standard SwapRouter02 from the first block,
///         and simulatable by every terminal/scanner. All LP NFTs are locked
///         forever in QuiverLpLockerV3; swap fees split creator/protocol.
contract QuiverV3 is OwnerAdmins, ReentrancyGuard {
    error Deprecated();
    error OnlyOriginatingChain();
    error InvalidPositions();
    error TeamFeeRecipientNotSet();
    error InvalidProtocolBps();

    /// @dev Identical signature to the v4 factory's event so the indexer needs
    ///      no new ABI: poolHook = address(0) marks a v3 launch, and poolId is
    ///      the v3 pool address left-padded to bytes32.
    event TokenCreated(
        address msgSender,
        address indexed tokenAddress,
        address indexed tokenAdmin,
        string tokenImage,
        string tokenName,
        string tokenSymbol,
        string tokenMetadata,
        string tokenContext,
        int24 startingTick,
        address poolHook,
        bytes32 poolId,
        address pairedToken,
        address locker,
        address mevModule,
        uint256 extensionsSupply,
        address[] extensions
    );
    event SetDeprecated(bool deprecated);
    event SetTeamFeeRecipient(address oldRecipient, address newRecipient);
    event SetProtocolBps(uint16 oldBps, uint16 newBps);

    string public constant version = "v3-1";

    uint256 public constant TOKEN_SUPPLY = 1_000_000_000e18; // 1b with 18 decimals
    uint256 public constant BPS = 10_000;
    uint24 public constant POOL_FEE = 10_000; // 1% fee tier
    int24 public constant TICK_SPACING = 200; // tick spacing of the 1% tier
    uint256 public constant MAX_POSITIONS = 10;

    IUniswapV3Factory public immutable uniswapV3Factory;
    ISwapRouter02 public immutable swapRouter;
    address public immutable weth;
    QuiverLpLockerV3 public immutable locker;

    // if true, the factory will not allow token deployments
    bool public deprecated;

    // protocol's share of LP fees, in bps; the creator receives the remainder
    uint16 public protocolBps;
    address public teamFeeRecipient;

    /// @dev Single-sided liquidity range, expressed as if the new token were
    ///      token0 (same convention as the v4 stack's tickIfToken0IsQuiver);
    ///      ticks are flipped internally when the token sorts as token1.
    struct PoolPosition {
        int24 tickLower;
        int24 tickUpper;
        uint16 bps; // share of pool supply in this range; all bps sum to 10_000
    }

    struct V3DeploymentInfo {
        address pool;
        int24 startingTick;
        address creatorRecipient;
    }

    mapping(address token => V3DeploymentInfo info) public deploymentInfoForToken;

    constructor(
        address owner_,
        address uniswapV3Factory_,
        address swapRouter_,
        address weth_,
        address locker_,
        uint16 protocolBps_
    ) OwnerAdmins(owner_) {
        uniswapV3Factory = IUniswapV3Factory(uniswapV3Factory_);
        swapRouter = ISwapRouter02(swapRouter_);
        weth = weth_;
        locker = QuiverLpLockerV3(locker_);
        if (protocolBps_ > BPS) revert InvalidProtocolBps();
        protocolBps = protocolBps_;

        // launches stay disabled until explicitly activated post-deploy
        deprecated = true;
    }

    function setDeprecated(bool deprecated_) external onlyOwner {
        deprecated = deprecated_;
        emit SetDeprecated(deprecated_);
    }

    function setTeamFeeRecipient(address teamFeeRecipient_) external onlyOwner {
        emit SetTeamFeeRecipient(teamFeeRecipient, teamFeeRecipient_);
        teamFeeRecipient = teamFeeRecipient_;
    }

    function setProtocolBps(uint16 protocolBps_) external onlyOwner {
        if (protocolBps_ > BPS) revert InvalidProtocolBps();
        emit SetProtocolBps(protocolBps, protocolBps_);
        protocolBps = protocolBps_;
    }

    /// @notice Deploy a token and seed its v3 pool. Any msg.value is used as a
    ///         same-tx initial buy ("dev buy") for the token admin.
    function deployToken(
        IQuiver.TokenConfig memory tokenConfig,
        int24 tickIfToken0IsQuiver,
        PoolPosition[] memory positions,
        address creatorRecipient
    ) external payable nonReentrant returns (address tokenAddress) {
        if (deprecated) revert Deprecated();
        if (block.chainid != tokenConfig.originatingChainId) revert OnlyOriginatingChain();
        if (teamFeeRecipient == address(0)) revert TeamFeeRecipientNotSet();
        if (positions.length == 0 || positions.length > MAX_POSITIONS) revert InvalidPositions();

        tokenAddress = QuiverDeployer.deployToken(tokenConfig, TOKEN_SUPPLY);

        address pool = _initializePool(tokenAddress, tickIfToken0IsQuiver);
        _placeLadder(tokenAddress, pool, positions, creatorRecipient);

        deploymentInfoForToken[tokenAddress] = V3DeploymentInfo({
            pool: pool,
            startingTick: tickIfToken0IsQuiver,
            creatorRecipient: creatorRecipient
        });

        // optional dev buy — the launch tx's ETH buys through the standard router
        if (msg.value > 0) {
            IWETH9(weth).deposit{value: msg.value}();
            IWETH9(weth).approve(address(swapRouter), msg.value);
            swapRouter.exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: weth,
                    tokenOut: tokenAddress,
                    fee: POOL_FEE,
                    recipient: tokenConfig.tokenAdmin,
                    amountIn: msg.value,
                    amountOutMinimum: 1,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        emit TokenCreated({
            msgSender: msg.sender,
            tokenAddress: tokenAddress,
            tokenAdmin: tokenConfig.tokenAdmin,
            tokenImage: tokenConfig.image,
            tokenName: tokenConfig.name,
            tokenSymbol: tokenConfig.symbol,
            tokenMetadata: tokenConfig.metadata,
            tokenContext: tokenConfig.context,
            startingTick: tickIfToken0IsQuiver,
            poolHook: address(0),
            poolId: bytes32(uint256(uint160(pool))),
            pairedToken: weth,
            locker: address(locker),
            mevModule: address(0),
            extensionsSupply: 0,
            extensions: new address[](0)
        });
    }

    function _initializePool(address token, int24 tickIfToken0IsQuiver)
        internal
        returns (address pool)
    {
        bool token0IsQuiver = token < weth;
        int24 startingTick = token0IsQuiver ? tickIfToken0IsQuiver : -tickIfToken0IsQuiver;

        pool = uniswapV3Factory.createPool(token, weth, POOL_FEE);
        IUniswapV3Pool(pool).initialize(TickMath.getSqrtPriceAtTick(startingTick));
    }

    /// @dev Validates and flips the ladder ranges, hands the pool supply to the
    ///      locker, and has the locker mint the positions directly on the pool
    ///      (raw positions owned by the locker — no NFT to misjudge).
    function _placeLadder(
        address token,
        address pool,
        PoolPosition[] memory positions,
        address creatorRecipient
    ) internal {
        bool token0IsQuiver = token < weth;

        QuiverLpLockerV3.PositionRange[] memory ranges =
            new QuiverLpLockerV3.PositionRange[](positions.length);
        uint256[] memory amounts = new uint256[](positions.length);

        uint256 totalBps;
        for (uint256 i = 0; i < positions.length; i++) {
            PoolPosition memory p = positions[i];
            totalBps += p.bps;

            // ranges are given in token0-is-quiver space; flip when token is token1
            (int24 lower, int24 upper) =
                token0IsQuiver ? (p.tickLower, p.tickUpper) : (-p.tickUpper, -p.tickLower);
            if (
                lower >= upper || lower % TICK_SPACING != 0 || upper % TICK_SPACING != 0
                    || p.bps == 0
            ) revert InvalidPositions();

            ranges[i] = QuiverLpLockerV3.PositionRange({tickLower: lower, tickUpper: upper});
            amounts[i] = TOKEN_SUPPLY * p.bps / BPS;
        }
        if (totalBps != BPS) revert InvalidPositions();

        address[] memory recipients = new address[](2);
        uint16[] memory rewardBps = new uint16[](2);
        recipients[0] = creatorRecipient;
        rewardBps[0] = uint16(BPS) - protocolBps;
        recipients[1] = teamFeeRecipient;
        rewardBps[1] = protocolBps;

        SafeERC20.safeTransfer(IERC20(token), address(locker), TOKEN_SUPPLY);
        locker.placeLiquidity(token, pool, ranges, amounts, recipients, rewardBps);
    }
}
