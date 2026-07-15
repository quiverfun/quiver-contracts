// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {QuiverRushDistributor} from "../src/rewards/QuiverRushDistributor.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RushDistributorTest is Test {
    QuiverRushDistributor dist;
    MockWETH weth;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        weth = new MockWETH();
        dist = new QuiverRushDistributor(owner, address(weth));
        weth.mint(address(dist), 100 ether);
    }

    function _leaf(uint256 seasonId, uint256 index, address account, uint256 amount)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(bytes.concat(keccak256(abi.encode(seasonId, index, account, amount))));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a <= b ? keccak256(bytes.concat(a, b)) : keccak256(bytes.concat(b, a));
    }

    /// Two-leaf tree: (alice, index 0), (bob, index 1); each proof is the sibling.
    function _twoLeafSeason(uint256 seasonId, uint256 amtA, uint256 amtB)
        internal
        returns (bytes32 leafA, bytes32 leafB)
    {
        leafA = _leaf(seasonId, 0, alice, amtA);
        leafB = _leaf(seasonId, 1, bob, amtB);
        vm.prank(owner);
        dist.setMerkleRoot(seasonId, _pair(leafA, leafB));
    }

    function test_claim_paysOut() public {
        (, bytes32 leafB) = _twoLeafSeason(1, 5 ether, 3 ether);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafB;

        dist.claim(1, 0, alice, 5 ether, proof);
        assertEq(weth.balanceOf(alice), 5 ether, "alice paid");
        assertTrue(dist.hasClaimed(1, alice), "marked claimed");
    }

    function test_claim_doubleClaimReverts() public {
        (, bytes32 leafB) = _twoLeafSeason(1, 5 ether, 3 ether);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafB;

        dist.claim(1, 0, alice, 5 ether, proof);
        vm.expectRevert(QuiverRushDistributor.AlreadyClaimed.selector);
        dist.claim(1, 0, alice, 5 ether, proof);
    }

    /// REGRESSION: a repeat winner with the SAME leaf index in a later season
    /// must be able to claim both seasons (the pulled-in version keyed claims
    /// by index and permanently locked repeat winners out).
    function test_repeatWinner_sameIndex_claimsBothSeasons() public {
        (, bytes32 s1LeafB) = _twoLeafSeason(1, 5 ether, 3 ether);
        (, bytes32 s2LeafB) = _twoLeafSeason(2, 7 ether, 2 ether);

        bytes32[] memory p1 = new bytes32[](1);
        p1[0] = s1LeafB;
        dist.claim(1, 0, alice, 5 ether, p1);

        bytes32[] memory p2 = new bytes32[](1);
        p2[0] = s2LeafB;
        dist.claim(2, 0, alice, 7 ether, p2);

        assertEq(weth.balanceOf(alice), 12 ether, "both seasons paid");
    }

    /// REGRESSION: publishing season 2 must not invalidate unclaimed season-1
    /// rewards (the pulled-in version overwrote the single root).
    function test_previousSeason_claimableAfterNewRoot() public {
        (, bytes32 s1LeafB) = _twoLeafSeason(1, 5 ether, 3 ether);
        _twoLeafSeason(2, 7 ether, 2 ether);

        bytes32[] memory p1 = new bytes32[](1);
        p1[0] = s1LeafB;
        dist.claim(1, 0, alice, 5 ether, p1);
        assertEq(weth.balanceOf(alice), 5 ether, "season 1 still claimable");
    }

    function test_rootImmutableOncePublished() public {
        _twoLeafSeason(1, 5 ether, 3 ether);
        vm.prank(owner);
        vm.expectRevert(QuiverRushDistributor.RootAlreadySet.selector);
        dist.setMerkleRoot(1, bytes32(uint256(123)));
    }

    function test_claim_invalidProofReverts() public {
        _twoLeafSeason(1, 5 ether, 3 ether);
        bytes32[] memory bad = new bytes32[](1);
        bad[0] = bytes32(uint256(42));
        vm.expectRevert(QuiverRushDistributor.InvalidProof.selector);
        dist.claim(1, 0, alice, 5 ether, bad);
    }

    function test_claim_wrongSeasonReverts() public {
        (, bytes32 leafB) = _twoLeafSeason(1, 5 ether, 3 ether);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafB;
        // no root for season 9
        vm.expectRevert(QuiverRushDistributor.RootNotSet.selector);
        dist.claim(9, 0, alice, 5 ether, proof);
    }

    function test_sweep_onlyOwner() public {
        vm.expectRevert();
        dist.sweep(address(weth), alice, 1 ether);

        vm.prank(owner);
        dist.sweep(address(weth), owner, 1 ether);
        assertEq(weth.balanceOf(owner), 1 ether, "swept");
    }

    function test_deposit_pulls() public {
        weth.mint(alice, 2 ether);
        vm.startPrank(alice);
        weth.approve(address(dist), 2 ether);
        dist.deposit(2 ether);
        vm.stopPrank();
        assertEq(weth.balanceOf(address(dist)), 102 ether, "deposited");
    }
}
