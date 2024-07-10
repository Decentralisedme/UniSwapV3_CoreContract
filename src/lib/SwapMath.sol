// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./FullMath.sol";
import "./SqrtPriceMath.sol";

/// @title Computes the result of a swap within ticks
/// @notice Contains methods for computing the result of a swap within a single tick price range, i.e., a single tick.
library SwapMath {
    /// @notice Computes the result of swapping some amount in, or amount out, given the parameters of the swap
    /// @dev The fee, plus the amount in, will never exceed the amount remaining if the swap's `amountSpecified` is positive
    /// @param sqrtRatioCurrentX96 The current sqrt price of the pool
    /// @param sqrtRatioTargetX96 The price that cannot be exceeded, from which the direction of the swap is inferred
    /// @param liquidity The usable liquidity
    /// @param amountRemaining How much input or output amount is remaining to be swapped in/out
    /// @param feePips The fee taken from the input amount, expressed in hundredths of a bip
    /// @return sqrtRatioNextX96 The price after swapping the amount in/out, not to exceed the price target
    /// @return amountIn The amount to be swapped in, of either token0 or token1, based on the direction of the swap
    /// @return amountOut The amount to be received, of either token0 or token1, based on the direction of the swap
    /// @return feeAmount The amount of input that will be taken as a fee
    function computeSwapStep(
        uint160 sqrtRatioCurrentX96,
        uint160 sqrtRatioTargetX96,
        uint128 liquidity,
        int256 amountRemaining,
        uint24 feePips
    ) internal pure returns (uint160 sqrtRatioNextX96, uint256 amountIn, uint256 amountOut, uint256 feeAmount) {
        // The Function:
        // 3 - Calc max amount in or amount out, depending if remaining is positive or negative number
        // Calc next sqrt ration - price
        // 4 - Calc amount in and out btwn current and next sqrt Ratio
        // 5 - Cap output amount to not exceed the remaining output amnt
        // 6 - Calc Fees on amnt in

        // -STEP 1: determin if is 041 or 140
        // - 041: put in token0 and get out token1
        // -- token 1 | token 0
        // -- <<<----041 Push tick to the left
        // - 140: put in token1 and get out token0
        // -- 140---->> Push tick to the right

        // How do we know which one? Since we have sqrt current and target Ratio
        // 041: target must be on left of current tick
        bool zeroForOne = sqrtRatioCurrentX96 >= sqrtRatioTargetX96;

        ///////////
        // -STEP 2: determin exactIn or excatOut: it depends on amnt remaining number (+IN/-OUT)
        bool exactIn = amountRemaining >= 0;

        ///////////
        // - STEP 3 - Calc max amount in or amount out nxt sqrtRatio
        if (exactIn) {
            uint256 amountInRemainingLessFee = FullMath.mulDiv(uint256(amountRemaining), 1e6 - feePips, 1e6);
            // Calc Max Amount IN and round it UP:for safety if round down may take more the require
            amountIn = zeroForOne
                // if this is 041 then token in is toekn0 >> we call getAmount0Delta / otherwise 1Delta (then change directions)
                ? SqrtPriceMath.getAmount0Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, true)
                : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, true);
            // Calc next sqrt ratio
            // Fee: from amnt In, but in case 1Delta if swap push current to Target >> fee taken from amount remaining
            // nxt sqrt ratio compares: amnt IN, amnt remaining - remaingLess Fee calc above
            if (amountInRemainingLessFee >= amountIn) {
                sqrtRatioNextX96 = sqrtRatioTargetX96;
            } else {
                sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                    sqrtRatioCurrentX96, liquidity, amountInRemainingLessFee, zeroForOne
                );
            }
        } else {
            // wen NOT EXACT IN >> nore amount remaining will be negative here
            // Calc Max Amount Out and round Down: otherwise we risk to taking out more then necessary
            amountOut = zeroForOne
                ? SqrtPriceMath.getAmount1Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, false)
                : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, false);
            // nxt sqrt ratio compares: amnt IN, amnt remaining - remaingLess Fee calc above
            if (uint256(-amountRemaining) >= amountOut) {
                sqrtRatioNextX96 = sqrtRatioTargetX96;
            } else {
                sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromOutput(
                    sqrtRatioCurrentX96, liquidity, uint256(-amountRemaining), zeroForOne
                );
            }
        }

        ////////////
        // - STEP 4 - Calc amount in and out btwn current and next sqrt Ratio:
        // --- This is the actual amount of Token coming in and out
        // - 4A: discover if the swap uses all the amount in or all the amnt out
        bool max = sqrtRatioTargetX96 == sqrtRatioNextX96;
        // This will have 4 cases:
        // 1. max and exactIn   --> in  = amountIn >> calc above
        //                       out = need to calculate
        // 2. max and !exactIn  --> in  = need to calculate
        //                       out = amountOut >> calc above
        // 3. !max and exactIn  --> in  = need to calculate
        //                       out = need to calculate
        // 4. !max and !exactIn --> in  = need to calculate
        //                       out = need to calculate
        //// code will split in  2 according  zerofor one

        if (zeroForOne) {
            // case: 041
            amountIn = max && exactIn
                ? amountIn
                : SqrtPriceMath.getAmount0Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, true);
            amountOut = max && !exactIn
                ? amountOut
                : SqrtPriceMath.getAmount1Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, false);
        } else {
            // case 140
            amountIn = max && exactIn
                ? amountIn
                : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, true);
            amountOut = max && !exactIn
                ? amountOut
                : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, false);
        }

        // STEP 5 - Cap output amount
        if (!exactIn && amountOut > uint256(-amountRemaining)) {
            amountOut = uint256(-amountRemaining);
        }

        // STEP 6 - Fee
        // Case 1: Ration Next does not reach target
        if (exactIn && sqrtRatioNextX96 != sqrtRatioTargetX96) {
            // we didn't reach the target, so take the remainder of the maximum input as fee
            feeAmount = uint256(amountRemaining) - amountIn;
        } else {
            // two situation
            // 1. swap is Not ExactIN
            // 2. swap is Exact in but ratio Next reach ratio Target
            // we need to calc fee = amountIn * %F / (1e6 - %F)
            // a = amountIn
            // f = feePips
            // x = Amount in needed to put amountIn + fee
            // fee = x*f

            // Solve for x
            // x = a + fee = a + x*f
            // x*(1 - f) = a
            // x = a / (1 - f)

            // Calculate fee
            // fee = x*f = a / (1 - f) * f

            // fee = a * f / (1 - f)

            feeAmount = FullMath.mulDivRoundingUp(amountIn, feePips, 1e6 - feePips);
        }
    }
}
