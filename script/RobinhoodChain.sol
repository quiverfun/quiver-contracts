// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// Robinhood Chain (4663) canonical deployments.
/// Verified on-chain 2026-07-14; see docs/CHAIN.md in the workspace.
library RobinhoodChain {
    uint256 constant CHAIN_ID = 4663;

    // Uniswap v4 (from developers.uniswap.org, bytecode verified)
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address constant QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Uniswap v3 (from developers.uniswap.org, verified on-chain 2026-07-15
    // via NPM.factory()/WETH9() cross-checks; see docs/CHAIN.md)
    address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant V3_POSITION_MANAGER = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address constant V3_SWAP_ROUTER_02 = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant V3_QUOTER_V2 = 0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7;

    // Canonical wrapped native (read from PositionManager.WETH9())
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
}
