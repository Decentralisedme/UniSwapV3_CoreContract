// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Contract for tick: https://github.com/Uniswap/v3-core/blob/main/contracts/libraries/Tick.sol
// This is a lib and we just need one function

import {TickMath} from "./TickMath.sol";

library Tick {
    struct Info {
        // the total position liquidity that references this tick
        uint128 liquidityGross;
        // amount of net liquidity added (subtracted) when tick is crossed from left to right (right to left),
        int128 liquidityNet;
        // fee growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
        // true iff the tick is initialized, i.e. the value is exactly equivalent to the expression liquidityGross != 0
        // these 8 bits are set to prevent fresh sstores when crossing newly initialized ticks
        bool initialized;
    }

    function tickSpacingToMaxLiquidityPerTick(int24 tickSpacing) internal pure returns (uint128) {
        int24 minTic = ((TickMath.MIN_TICK / tickSpacing) * tickSpacing);
        int24 maxTic = ((TickMath.MAX_TICK / tickSpacing) * tickSpacing);
        uint24 numbTick = uint24((maxTic - minTic) / tickSpacing) + 1;
        return type(uint128).max / numbTick;
    }

    function update(
        mapping(int24 => Tick.Info) storage self, // this is ticks
        int24 tick,
        int24 tickCurrent, // Slot0
        int128 liquidityDelta,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        bool upper,
        uint128 maxLiquidity
    )
        // bool flippe: true wen liquidity is activated or deactivated, otherwise false
        // Also: if Liq = 0, the after calling function Liq>0 then flipped = true
        // Also: if Liq > 0, the after calling function Liq=0 then flipped = true
        internal
        returns (bool flipped)
    {
        Info memory info = self[tick];

        uint128 liquidityGrossBefore = info.liquidityGross;
        // grossAfter = uint128 GrossBefore + int128 LDelta >> Need some int work
        uint128 liquidityGrossAfter = liquidityDelta < 0
            ? liquidityGrossBefore - uint128(-liquidityDelta)
            : liquidityGrossBefore + uint128(liquidityDelta);

        //Ceck max Liq
        require(liquidityGrossAfter <= maxLiquidity, "Liq > max Liq");

        // Flipped: this can also be writen
        // flipped = (liquidityGrossBefore == 0 && liquidityGrossAfter > 0)
        //     || (liquidityGrossBefore > 0 && liquidityGrossAfter == 0);
        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        // case GrossBe ==0 >> initialise
        if (liquidityGrossBefore == 0) {
            info.initialized = true;
        }
        // Update liqGross with liqGrossAfter
        info.liquidityGross = liquidityGrossAfter;
        // LiqNet:depends on ticks
        // If upper tick we subtract (we store the negative) liqDelta oterwise we add
        info.liquidityNet = upper ? info.liquidityNet - liquidityDelta : info.liquidityNet + liquidityDelta;
    }

    function clear(mapping(int24 => Info) storage self, int24 tick) internal {
        delete self[tick];
    }
}
