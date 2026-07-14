// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {QuiverHook} from "./QuiverHook.sol";
import {IQuiverHookStaticFee} from "./interfaces/IQuiverHookStaticFee.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract QuiverHookStaticFee is QuiverHook, IQuiverHookStaticFee {
    mapping(PoolId => uint24) public quiverFee;
    mapping(PoolId => uint24) public pairedFee;

    constructor(address _poolManager, address _factory, address _weth)
        QuiverHook(_poolManager, _factory, _weth)
    {}

    function _initializePoolData(PoolKey memory poolKey, bytes memory poolData) internal override {
        PoolStaticConfigVars memory _poolConfigVars = abi.decode(poolData, (PoolStaticConfigVars));

        if (_poolConfigVars.quiverFee > MAX_LP_FEE) {
            revert QuiverFeeTooHigh();
        }

        if (_poolConfigVars.pairedFee > MAX_LP_FEE) {
            revert PairedFeeTooHigh();
        }

        quiverFee[poolKey.toId()] = _poolConfigVars.quiverFee;
        pairedFee[poolKey.toId()] = _poolConfigVars.pairedFee;

        emit PoolInitialized(poolKey.toId(), _poolConfigVars.quiverFee, _poolConfigVars.pairedFee);
    }

    // set the LP fee according to the quiver/paired fee configuration
    function _setFee(PoolKey calldata poolKey, IPoolManager.SwapParams calldata swapParams)
        internal
        override
    {
        uint24 fee = swapParams.zeroForOne != quiverIsToken0[poolKey.toId()]
            ? pairedFee[poolKey.toId()]
            : quiverFee[poolKey.toId()];

        _setProtocolFee(fee);
        IPoolManager(poolManager).updateDynamicLPFee(poolKey, fee);
    }
}
