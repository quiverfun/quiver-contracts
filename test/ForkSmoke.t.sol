// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {RobinhoodChain} from "../script/RobinhoodChain.sol";

/// Proves the toolchain: compiles against vendored v4 libs and fork-reads
/// the live Uniswap v4 deployment on Robinhood Chain.
contract ForkSmokeTest is Test {
    function setUp() public {
        vm.createSelectFork("robinhood");
    }

    function test_chainId() public view {
        assertEq(block.chainid, RobinhoodChain.CHAIN_ID);
    }

    function test_uniswapV4Deployed() public view {
        assertGt(RobinhoodChain.POOL_MANAGER.code.length, 0, "PoolManager missing");
        assertGt(RobinhoodChain.POSITION_MANAGER.code.length, 0, "PositionManager missing");
        assertGt(RobinhoodChain.UNIVERSAL_ROUTER.code.length, 0, "UniversalRouter missing");
        assertGt(RobinhoodChain.STATE_VIEW.code.length, 0, "StateView missing");
    }
}
