// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IQuiver} from "./IQuiver.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IQuiverMevModule {
    error PoolLocked();
    error OnlyHook();

    // initialize the mev module
    function initialize(PoolKey calldata poolKey, bytes calldata mevModuleInitData) external;

    // before a swap, call the mev module
    function beforeSwap(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        bool quiverIsToken0,
        bytes calldata mevModuleSwapData
    ) external returns (bool disableMevModule);

    // implements the IQuiverMevModule interface
    function supportsInterface(bytes4 interfaceId) external pure returns (bool);
}
