// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {INonfungiblePositionManager} from "./interfaces/IUniswapV3.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title QuiverLpLockerV3
/// @notice Permanently holds the Uniswap v3 LP position NFTs for tokens launched
///         by the Quiver v3 factory. There is deliberately NO code path that can
///         decrease liquidity or transfer a position out — liquidity is locked
///         forever; only accrued swap fees can be collected and distributed.
contract QuiverLpLockerV3 is Ownable, ReentrancyGuard {
    error OnlyFactory();
    error AlreadyRegistered();
    error UnknownToken();
    error InvalidRewards();
    error OnlyRecipient();
    error OnlyPositionManager();

    event TokenRegistered(
        address indexed token, uint256[] positionIds, address[] recipients, uint16[] rewardBps
    );
    event RewardsCollected(
        address indexed token, uint256 amount0, uint256 amount1, address currency0, address currency1
    );
    event RewardRecipientUpdated(
        address indexed token, uint256 index, address oldRecipient, address newRecipient
    );

    uint256 public constant BPS = 10_000;

    INonfungiblePositionManager public immutable positionManager;

    // the Quiver v3 factory allowed to register launches
    address public factory;

    struct TokenRewards {
        uint256[] positionIds;
        address[] recipients;
        uint16[] rewardBps; // sums to BPS
        address currency0;
        address currency1;
        bool exists;
    }

    mapping(address token => TokenRewards) internal _rewards;

    constructor(address owner_, address positionManager_) Ownable(owner_) {
        positionManager = INonfungiblePositionManager(positionManager_);
    }

    function setFactory(address factory_) external onlyOwner {
        factory = factory_;
    }

    /// @notice Called by the factory at launch, after minting positions to this contract.
    function register(
        address token,
        uint256[] calldata positionIds,
        address[] calldata recipients,
        uint16[] calldata rewardBps,
        address currency0,
        address currency1
    ) external {
        if (msg.sender != factory) revert OnlyFactory();
        if (_rewards[token].exists) revert AlreadyRegistered();
        if (recipients.length == 0 || recipients.length != rewardBps.length) {
            revert InvalidRewards();
        }

        uint256 totalBps;
        for (uint256 i = 0; i < rewardBps.length; i++) {
            if (recipients[i] == address(0)) revert InvalidRewards();
            totalBps += rewardBps[i];
        }
        if (totalBps != BPS) revert InvalidRewards();

        _rewards[token] = TokenRewards({
            positionIds: positionIds,
            recipients: recipients,
            rewardBps: rewardBps,
            currency0: currency0,
            currency1: currency1,
            exists: true
        });

        emit TokenRegistered(token, positionIds, recipients, rewardBps);
    }

    /// @notice Collect accrued swap fees for a token's positions and distribute
    ///         both currencies pro-rata to the reward recipients. Anyone can call.
    function collectRewards(address token) external nonReentrant {
        TokenRewards storage r = _rewards[token];
        if (!r.exists) revert UnknownToken();

        uint256 total0;
        uint256 total1;
        for (uint256 i = 0; i < r.positionIds.length; i++) {
            (uint256 a0, uint256 a1) = positionManager.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: r.positionIds[i],
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
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
            uint256[] memory positionIds,
            address[] memory recipients,
            uint16[] memory rewardBps
        )
    {
        TokenRewards storage r = _rewards[token];
        return (r.positionIds, r.recipients, r.rewardBps);
    }

    /// @dev Accept position NFTs only from the canonical position manager.
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (msg.sender != address(positionManager)) revert OnlyPositionManager();
        return this.onERC721Received.selector;
    }
}
