// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
// UniV3:https://github.com/Uniswap/v3-core/blob/main/contracts/UniswapV3Pool.sol

import {Tick} from "./lib/Tick.sol";
import {TickMath} from "./lib/TickMath.sol";
import {Position} from "./lib/Position.sol";
import {SafeCast} from "./lib/SafeCast.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {SqrtPriceMath} from "./lib/SqrtPriceMath.sol";
import {SwapMath} from "./lib/SwapMath.sol";

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

    // ..........
    // Struct Swap
    // ...........
    struct SwapCache {
        // liquidity at the beginning of the swap
        uint128 liquidityStart;
    }

    // the top level state of the swap, the results of which are recorded in storage at the end
    struct SwapState {
        // the amount remaining to be swapped in/out of the input/output asset
        int256 amountSpecifiedRemaining;
        // the amount already swapped out/in of the output/input asset
        int256 amountCalculated;
        // current sqrt(price)
        uint160 sqrtPriceX96;
        // the tick associated with the current price
        int24 tick;
        // the global fee growth of the input token
        uint256 feeGrowthGlobalX128;
        // the current liquidity in range
        uint128 liquidity;
    }

    struct StepComputations {
        // the price at the beginning of the step
        uint160 sqrtPriceStartX96;
        // the next tick to swap to from the current tick in the swap direction
        int24 tickNext;
        // whether tickNext is initialized or not
        bool initialized;
        // sqrt(price) for the next tick (1/0)
        uint160 sqrtPriceNextX96;
        // how much is being swapped in in this step
        uint256 amountIn;
        // how much is being swapped out
        uint256 amountOut;
        // how much fee is being paid in
        uint256 feeAmount;
    }

    Slot0 public slot0;
    uint128 public liquidity;
    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;

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

        // We have 3 cases:
        // 1- Current Pr < LowerPr range
        // 2- LowerPr range < Current Pr < UpperPr range
        // 3- Current Pr > UpperPr range
        // We write the 3 codition in side a require LiqDelta != 0
        if (params.liquidityDelta != 0) {
            // 1
            if (_slot0.tick < params.tickLower) {
                // All liq in token0
                amount0 = SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
                //sqrtRatioAX96, sqrtRatioBX96, liquidity, roundUp);
            } else if (_slot0.tick < params.tickUpper) {
                // 2
                amount0 = SqrtPriceMath.getAmount0Delta(
                    _slot0.sqrtPriceX96, //current price
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    _slot0.sqrtPriceX96, //current price
                    params.liquidityDelta
                );
                // update Liq
                liquidity = params.liquidityDelta < 0
                    ? liquidity - uint128(-params.liquidityDelta)
                    : liquidity + uint128(params.liquidityDelta);
            } else {
                // 3- All liq in token0
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            }
        }

        // Info storage is storage state variable: w need a mapping No Need Anymore
        // return (positions[bytes32(0)], 0, 0);
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

    // ....................
    // - External Functions
    // ....................
    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external lock returns (uint128 amount0, uint128 amount1) {
        // get the position: since updateing state variable position >> storage
        Position.Info storage position = positions.get(msg.sender, tickLower, tickUpper);
        // calc actual amount of token to be transfer out of the Pool
        // Read: if amnt0Req > positionTokenOwed then amount = tokenOwed, otehrwise (:) amountRequested
        amount0 = amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : amount1Requested;

        // Update Positions and transfer
        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            // Here in CoreV3 code uses safeTransfer, we keep simple
            IERC20(token0).transfer(recipient, amount0);
        }
        if (amount0 > 0) {
            position.tokensOwed1 -= amount1;
            // Here in CoreV3 code uses safeTransfer, we keep simple
            IERC20(token1).transfer(recipient, amount1);
        }
    }

    // burn funct does not transfer any token, to do so you need to use collect
    function burn(int24 tickLower, int24 tickUpper, uint128 amount)
        external
        lock
        returns (uint256 amount0, uint256 amount1)
    {
        // amount to remove = liquidityDelta
        // So LiqDelta must be negative and since liq is int128 >> toInt128()
        // So also amount0Int and amount1Int must be neg >> we need to cast
        (Position.Info memory position, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: msg.sender,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(uint256(amount)).toInt128() // this amount to remove >> negative also buing liq must be in128
            })
        );
        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        if (amount0 > 0 || amount1 > 0) {
            (position.tokensOwed0, position.tokensOwed1) =
                (position.tokensOwed0 + uint128(amount0), position.tokensOwed1 + uint128(amount1));
        }
    }

    function swap(
        address recipient,
        bool zeroForOne, // 041/140
        int256 amountSpecified, // + >> excatIn / - >> excatOut
        uint160 sqrtPriceLimitX96 // if curretn sqrtPrice reaches the limit - trade ll stop
            // bytes calldata data // we are not using this
    ) external lock returns (int256 amount0, int256 amount1) {
        require(amountSpecified != 0);

        Slot0 memory slot0Start = slot0;

        // sqrtPriceLinit: wer it is depends if swap041 or 140
        // 041 >> will push price to the left >> sqrtPriceLinit should be left of CurretnPrice
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO
                : sqrtPriceLimitX96 > slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 < TickMath.MIN_SQRT_RATIO,
            "Invalid sqrt Price Limit"
        );

        // struct SwapCash
        SwapCache memory cache = SwapCache({liquidityStart: liquidity});

        bool exactInput = amountSpecified > 0;

        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0Start.sqrtPriceX96,
            tick: slot0Start.tick,
            feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128,
            liquidity: cache.liquidityStart
        });

        // amountCalculated: while loop ToDo
        while (true) {}
        // update tick and write an oracle entry if the tick change

        // Update sqrtPriceX96 and tick, if not same then update
        if (state.tick != slot0Start.tick) {
            (slot0.sqrtPriceX96, slot0.tick) = (state.sqrtPriceX96, state.tick);
        } else {
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }

        // UPdate Liquidity -liqStart is before we do the trade
        if (cache.liquidityStart != state.liquidity) {
            liquidity = state.liquidity;
        }

        // Update fee global
        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
        }
        // Calc amount tokenIn and tokenOut
        // list of conditions:
        // Set amount0 and amount1
        // zero for one | exact input |
        //    true      |    true     | amount 0 = specified - remaining (> 0)
        //              |             | amount 1 = calculated            (< 0)
        //    false     |    false    | amount 0 = specified - remaining (< 0)
        //              |             | amount 1 = calculated            (> 0)
        //    false     |    true     | amount 0 = calculated            (< 0)
        //              |             | amount 1 = specified - remaining (> 0)
        //    true      |    false    | amount 0 = calculated            (> 0)
        //              |             | amount 1 = specified - remaining (< 0)
        (amount0, amount1) = zeroForOne == exactInput
            ? (amountSpecified - state.amountSpecifiedRemaining, state.amountCalculated)
            : (state.amountCalculated, amountSpecified - state.amountSpecifiedRemaining);

        // Trabsfer the Tokens
        if (zeroForOne) {
            if (amount1 < 0) {
                IERC20(token1).transfer(recipient, uint256(-amount1));
                IERC20(token0).transferFrom(msg.sender, address(this), uint256(amount0));
            }
        } else {
            if (amount0 < 0) {
                IERC20(token0).transfer(recipient, uint256(-amount0));
                IERC20(token1).transferFrom(msg.sender, address(this), uint256(amount1));
            }
        }
    }
}
