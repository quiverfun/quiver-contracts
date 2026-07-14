// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {QuiverToken} from "../QuiverToken.sol";
import {IQuiver} from "../interfaces/IQuiver.sol";

/// @notice Quiver Token Launcher
library QuiverDeployer {
    function deployToken(IQuiver.TokenConfig memory tokenConfig, uint256 supply)
        external
        returns (address tokenAddress)
    {
        QuiverToken token = new QuiverToken{
            salt: keccak256(abi.encode(tokenConfig.tokenAdmin, tokenConfig.salt))
        }(
            tokenConfig.name,
            tokenConfig.symbol,
            supply,
            tokenConfig.tokenAdmin,
            tokenConfig.image,
            tokenConfig.metadata,
            tokenConfig.context,
            tokenConfig.originatingChainId
        );
        tokenAddress = address(token);
    }
}
