// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
// UniV3:https://github.com/Uniswap/v3-core/blob/main/contracts/UniswapV3Pool.sol

import {Tick} from "./lib/Tick.sol";
import {TickMath} from "./lib/TickMath.sol";
import {Position} from "./lib/Position.sol";
import {SafeCast} from "./lib/SafeCast.sol";
import {IERC20} from "./interfaces/IERC20.sol";

contract CLAMM {
    using SafeCast for int256;
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    using Tick for mapping(int24 => Tick.Info);

    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    uint128 public immutable maxLiquidityPerTick;

    //////////
    //Structs
    /////////
    struct Slot0 {
        // the current price
        uint160 sqrtPriceX96;
        // the current tick
        int24 tick;
        // whether the pool is locked
        bool unlocked;
    }

    struct ModifyPositionParams {
        // the address that owns the position
        address owner;
        // the lower and upper tick of the position
        int24 tickLower;
        int24 tickUpper;
        // any change in liquidity
        int128 liquidityDelta;
    }

    Slot0 public slot0;

    ///////////
    // Mappings
    ///////////
    mapping(bytes32 => Position.Info) public positions;
    mapping(int24 => Tick.Info) public ticks;

    /////////////
    // Modifiers:
    ////////////
    // Reentrency Gard
    modifier lock() {
        require(slot0.unlocked, "locked");
        slot0.unlocked = false;
        _; // execute the code then
        slot0.unlocked = true;
    }

    constructor(address _token0, address _token1, uint24 _fee, int24 _tickSpacing) {
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        tickSpacing = _tickSpacing;
        maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(tickSpacing);
    }

    ////////////
    // Functions
    ////////////

    // It initialises the price, if not = 0
    function initialize(uint160 sqrtPriceX96) external {
        // Make sure it cannot be called more then once
        require(slot0.sqrtPriceX96 == 0, "Already Initialised");
        // Compute the tick using function getTickAtSqrtRatio()
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);
        // Initialize Slot0
        slot0 = Slot0({sqrtPriceX96: sqrtPriceX96, tick: tick, unlocked: true});
    }

    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount)
        external
        lock
        returns (uint256 amount0, uint256 amount1)
    {
        require(amount > 0, "Amount is = 0");
        // Modify Position: once called, it will also calc amount token0, token1
        // these amnt are int256 not uint >> can be negative
        // they depends on Liquidity Delta: if LDelta is <0 >> amnt <0
        // we adding liquidity (amount >0) so amount0/1int >0
        (, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: recipient,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(amount)).toInt128()
            })
        );
        // we have the amount0/1 we now need to cast them
        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

        // Transfer the tokens
        if (amount0 > 0) IERC20(token0).transferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) IERC20(token1).transferFrom(msg.sender, address(this), amount1);
    }

    // ....................
    // - Privates Functions
    // ....................

    // Arg is the struct and retuns 3 values: first is info storage is struct from Position.sol
    function _modifyPosition(ModifyPositionParams memory params)
        private
        returns (Position.Info storage position, int256 amount0, int256 amount1)
    {
        // 1- check the ticks
        checkTicks(params.tickLower, params.tickUpper);
        // 2- Optimise gas: put Slot0 in memory: read from storage is very expencies
        Slot0 memory _slot0 = slot0;
        // 3- call function to update position
        position = _updatePosition(params.owner, params.tickLower, params.tickUpper, params.liquidityDelta, _slot0.tick);

        // Info storage is storage state variable: w need a mapping
        return (positions[bytes32(0)], 0, 0);
    }

    function checkTicks(int24 tickLower, int24 tickUpper) private pure {
        require(tickLower < tickUpper);
        require(tickLower >= TickMath.MIN_TICK);
        require(tickUpper <= TickMath.MAX_TICK);
    }

    function _updatePosition(address owner, int24 tickLower, int24 tickUpper, int128 liquidityDelta, int24 tick)
        private
        returns (Position.Info storage position)
    {
        // 1- get position as state varaible
        position = positions.get(owner, tickLower, tickUpper);

        // 2- State Var related to fees:
        uint256 _feeGrowthGlobal0X128 = 0;
        uint256 _feeGrowthGlobal1X128 = 0;

        // if we need to update the ticks, do it
        bool flippedLower;
        bool flippedUpper;
        // IF LiqDelta not 0
        if (liquidityDelta != 0) {
            flippedLower = ticks.update(
                tickLower,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                false,
                maxLiquidityPerTick
            );
        }
        if (liquidityDelta != 0) {
            flippedUpper = ticks.update(
                tickUpper, tick, liquidityDelta, _feeGrowthGlobal0X128, _feeGrowthGlobal1X128, true, maxLiquidityPerTick
            );

            // Update the posotion: ToDO Fees (0,0)
            position.update(liquidityDelta, 0, 0);

            // If liqDelta < 0 >>> we removing liquidity
            if (liquidityDelta < 0) {
                if (flippedLower) {
                    ticks.clear(tickLower);
                }
                if (flippedUpper) {
                    ticks.clear(tickUpper);
                }
            }
        }
    }
}
