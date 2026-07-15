// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title QuiverRushDistributor
/// @notice Merkle distributor for seasonal Quiver Rush WETH rewards.
/// @dev Every season keeps its own root and its own claim bitmap, so
///      (a) publishing season N+1 never invalidates unclaimed season-N rewards
///      and (b) a wallet that wins the same leaf index in two seasons (top
///      traders repeat!) can claim both. Leaves bind the seasonId:
///      keccak256(bytes.concat(keccak256(abi.encode(seasonId, index, account, amount))))
contract QuiverRushDistributor is Ownable2Step {
    using SafeERC20 for IERC20;

    error RootAlreadySet();
    error RootNotSet();
    error AlreadyClaimed();
    error InvalidProof();

    IERC20 public immutable weth;

    mapping(uint256 seasonId => bytes32 root) public merkleRoots;
    mapping(uint256 seasonId => mapping(address account => bool claimed)) public hasClaimed;

    event Deposited(address indexed from, uint256 amount);
    event MerkleRootSet(uint256 indexed seasonId, bytes32 indexed root);
    event Claimed(
        uint256 indexed seasonId, uint256 index, address indexed account, uint256 amount
    );
    event Swept(address indexed token, address indexed to, uint256 amount);

    constructor(address initialOwner, address weth_) Ownable(initialOwner) {
        weth = IERC20(weth_);
    }

    /// @notice Fund the distributor with WETH (pull; requires prior approve).
    function deposit(uint256 amount) external {
        weth.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount);
    }

    /// @notice Publish a season's merkle root after off-chain settlement.
    ///         One shot per season — roots are immutable once set, so a
    ///         published season can never be rewritten out from under claimers.
    function setMerkleRoot(uint256 seasonId, bytes32 root) external onlyOwner {
        if (merkleRoots[seasonId] != bytes32(0)) revert RootAlreadySet();
        merkleRoots[seasonId] = root;
        emit MerkleRootSet(seasonId, root);
    }

    /// @notice Claim a seasonal WETH reward with a merkle proof. Callable by
    ///         anyone; funds always go to the leaf's account.
    function claim(
        uint256 seasonId,
        uint256 index,
        address account,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) external {
        bytes32 root = merkleRoots[seasonId];
        if (root == bytes32(0)) revert RootNotSet();
        if (hasClaimed[seasonId][account]) revert AlreadyClaimed();

        bytes32 leaf =
            keccak256(bytes.concat(keccak256(abi.encode(seasonId, index, account, amount))));
        if (!MerkleProof.verify(merkleProof, root, leaf)) revert InvalidProof();

        hasClaimed[seasonId][account] = true;
        weth.safeTransfer(account, amount);
        emit Claimed(seasonId, index, account, amount);
    }

    /// @notice Recover stale funds (e.g. rewards unclaimed long after a season
    ///         ends, or tokens sent here by mistake). The owner already
    ///         controls roots, so this adds no new trust assumption.
    function sweep(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
        emit Swept(token, to, amount);
    }
}
