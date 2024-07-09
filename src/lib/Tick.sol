// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contract for tick: https://github.com/Uniswap/v3-core/blob/main/contracts/libraries/Tick.sol
// This is a lib and we just need one function

import {TickMath} from "./TickMath.sol";

library Tick {
    function tickSpacingToMaxLiquidityPerTick(int24 tickSpacing) internal pure returns (uint128) {
        int24 minTic = ((TickMath.MIN_TICK / tickSpacing) * tickSpacing);
        int24 maxTic = ((TickMath.MAX_TICK / tickSpacing) * tickSpacing);
        uint24 numbTick = uint24((maxTic - minTic) / tickSpacing) + 1;
        return type(uint128).max / numbTick;
    }
}
