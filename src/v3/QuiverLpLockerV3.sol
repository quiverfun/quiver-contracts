// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IUniswapV3Pool} from "./interfaces/IUniswapV3.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @title QuiverLpLockerV3
/// @notice Permanently owns the Uniswap v3 liquidity for tokens launched by the
///         Quiver v3 factory, as RAW pool positions (direct pool.mint) rather
///         than position-manager NFTs. There is deliberately NO code path that
///         can withdraw liquidity: `pool.burn` is only ever called with
///         liquidity = 0 (the standard fee-poke), so the positions are
///         structurally unruggable — equivalent to burnt LP, but with swap
///         fees still collectable and split between creator and protocol.
contract QuiverLpLockerV3 is Ownable, ReentrancyGuard {
    error OnlyFactory();
    error AlreadyRegistered();
    error UnknownToken();
    error InvalidRewards();
    error OnlyRecipient();
    error UnexpectedCallback();

    event LiquidityPlaced(address indexed token, address indexed pool, uint256 positions);
    event RewardsCollected(
        address indexed token, uint256 amount0, uint256 amount1, address currency0, address currency1
    );
    event RewardRecipientUpdated(
        address indexed token, uint256 index, address oldRecipient, address newRecipient
    );

    uint256 public constant BPS = 10_000;

    // the Quiver v3 factory allowed to place liquidity
    address public factory;

    struct PositionRange {
        int24 tickLower;
        int24 tickUpper;
    }

    struct TokenRewards {
        address pool;
        PositionRange[] positions;
        address[] recipients;
        uint16[] rewardBps; // sums to BPS
        address currency0;
        address currency1;
        bool exists;
    }

    mapping(address token => TokenRewards) internal _rewards;

    // pool allowed to invoke the mint callback, set only inside placeLiquidity
    address private _pendingPool;

    constructor(address owner_) Ownable(owner_) {}

    function setFactory(address factory_) external onlyOwner {
        factory = factory_;
    }

    /// @notice Called by the factory at launch. The factory transfers the pool
    ///         supply to this contract first; each range is minted directly on
    ///         the pool with this locker as the position owner.
    /// @param ranges     pool-space tick ranges (already flipped for ordering)
    /// @param amounts    token amount to place in each range
    function placeLiquidity(
        address token,
        address pool,
        PositionRange[] calldata ranges,
        uint256[] calldata amounts,
        address[] calldata recipients,
        uint16[] calldata rewardBps
    ) external nonReentrant {
        if (msg.sender != factory) revert OnlyFactory();
        if (_rewards[token].exists) revert AlreadyRegistered();
        if (ranges.length == 0 || ranges.length != amounts.length) revert InvalidRewards();
        if (recipients.length == 0 || recipients.length != rewardBps.length) {
            revert InvalidRewards();
        }

        uint256 totalBps;
        for (uint256 i = 0; i < rewardBps.length; i++) {
            if (recipients[i] == address(0)) revert InvalidRewards();
            totalBps += rewardBps[i];
        }
        if (totalBps != BPS) revert InvalidRewards();

        address currency0 = IUniswapV3Pool(pool).token0();
        address currency1 = IUniswapV3Pool(pool).token1();
        bool tokenIs0 = token == currency0;

        TokenRewards storage r = _rewards[token];
        r.pool = pool;
        r.recipients = recipients;
        r.rewardBps = rewardBps;
        r.currency0 = currency0;
        r.currency1 = currency1;
        r.exists = true;

        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();

        _pendingPool = pool;
        for (uint256 i = 0; i < ranges.length; i++) {
            uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(ranges[i].tickLower),
                TickMath.getSqrtPriceAtTick(ranges[i].tickUpper),
                tokenIs0 ? amounts[i] : 0,
                tokenIs0 ? 0 : amounts[i]
            );
            IUniswapV3Pool(pool).mint(
                address(this), ranges[i].tickLower, ranges[i].tickUpper, liquidity, ""
            );
            r.positions.push(ranges[i]);
        }
        _pendingPool = address(0);

        // liquidity math rounds down — park the leftover wei at 0xdead so the
        // locker never shows a raw balance of a launched token
        uint256 dust = IERC20(token).balanceOf(address(this));
        if (dust > 0) {
            SafeERC20.safeTransfer(IERC20(token), address(0xdead), dust);
        }

        emit LiquidityPlaced(token, pool, ranges.length);
    }

    /// @dev v3 mint callback: pay the pool what the mint owes, from the supply
    ///      the factory transferred in. Only the pool being minted may call.
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata)
        external
    {
        if (msg.sender != _pendingPool || _pendingPool == address(0)) revert UnexpectedCallback();
        if (amount0Owed > 0) {
            SafeERC20.safeTransfer(IERC20(IUniswapV3Pool(msg.sender).token0()), msg.sender, amount0Owed);
        }
        if (amount1Owed > 0) {
            SafeERC20.safeTransfer(IERC20(IUniswapV3Pool(msg.sender).token1()), msg.sender, amount1Owed);
        }
    }

    /// @notice Collect accrued swap fees for a token's positions and distribute
    ///         both currencies pro-rata to the reward recipients. Anyone can call.
    function collectRewards(address token) external nonReentrant {
        TokenRewards storage r = _rewards[token];
        if (!r.exists) revert UnknownToken();

        uint256 total0;
        uint256 total1;
        for (uint256 i = 0; i < r.positions.length; i++) {
            PositionRange memory p = r.positions[i];
            // poke with zero liquidity so the pool accounts fees owed — this is
            // the ONLY use of burn() in this contract, and always with 0
            IUniswapV3Pool(r.pool).burn(p.tickLower, p.tickUpper, 0);
            (uint256 a0, uint256 a1) = IUniswapV3Pool(r.pool).collect(
                address(this), p.tickLower, p.tickUpper, type(uint128).max, type(uint128).max
            );
            total0 += a0;
            total1 += a1;
        }

        uint256 n = r.recipients.length;
        for (uint256 i = 0; i < n; i++) {
            // last recipient takes the remainder so rounding dust never accrues
            uint256 share0 = i == n - 1 ? IERC20(r.currency0).balanceOf(address(this))
                : total0 * r.rewardBps[i] / BPS;
            uint256 share1 = i == n - 1 ? IERC20(r.currency1).balanceOf(address(this))
                : total1 * r.rewardBps[i] / BPS;
            if (share0 > 0) SafeERC20.safeTransfer(IERC20(r.currency0), r.recipients[i], share0);
            if (share1 > 0) SafeERC20.safeTransfer(IERC20(r.currency1), r.recipients[i], share1);
        }

        emit RewardsCollected(token, total0, total1, r.currency0, r.currency1);
    }

    /// @notice A reward recipient can reassign its own slot (e.g. rotate a wallet).
    function updateRewardRecipient(address token, uint256 index, address newRecipient) external {
        TokenRewards storage r = _rewards[token];
        if (!r.exists) revert UnknownToken();
        if (msg.sender != r.recipients[index]) revert OnlyRecipient();
        if (newRecipient == address(0)) revert InvalidRewards();

        address old = r.recipients[index];
        r.recipients[index] = newRecipient;
        emit RewardRecipientUpdated(token, index, old, newRecipient);
    }

    function tokenRewards(address token)
        external
        view
        returns (
            address pool,
            PositionRange[] memory positions,
            address[] memory recipients,
            uint16[] memory rewardBps
        )
    {
        TokenRewards storage r = _rewards[token];
        return (r.pool, r.positions, r.recipients, r.rewardBps);
    }
}
