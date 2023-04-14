// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "./Math.sol";

library SwapMath {
    function computeSwapStep(
        //一个价格区间内部的交易数量以及对应的流动性 dertaX与L
        uint160 sqrtPriceCurrentX96,
        uint160 sqrtPriceTargetX96,
        uint128 liquidity,
        uint256 amountRemaining, //还需要从池子拿多少token
        uint24 fee
    )
        internal
        pure
        returns (
            //返回新的现价
            uint160 sqrtPriceNextX96,
            uint256 amountIn,
            uint256 amountOut,
            uint256 feeAmount
        )
    {
        //定义方向
        bool zeroForOne = sqrtPriceCurrentX96 >= sqrtPriceTargetX96;
        //在输入的 token 中减去了交易费用
        //并且用这个小一点的结果计算输出数量
        uint256 amountRemainingLessFee = mulDiv( // x*y/z
            amountRemaining,
            1e6 - fee,
            1e6
        );
        //计算整个区间能提供的流动性
        amountIn = zeroForOne
            ? Math.calcAmount0Delta(
                sqrtPriceCurrentX96,
                sqrtPriceTargetX96,
                liquidity,
                true
            )
            : Math.calcAmount1Delta(
                sqrtPriceCurrentX96,
                sqrtPriceTargetX96,
                liquidity,
                true
            );
        //计算交易amountRemaining 数量 token 之后的价格
        /**如果没有达到上界，现在的价格区间有足够的流动性来填满交易，
        因此我们只需要返回填满交易所需数量与实际数量之间的差即可。 */
        //1.如果整个区间的dertaX不够
        if (amountRemainingLessFee >= amountIn)
            sqrtPriceNextX96 = sqrtPriceTargetX96;
            //2.整个区间够了 则计算在这个区间的价格
        else
            sqrtPriceNextX96 = Math.getNextSqrtPriceFromInput(
                sqrtPriceCurrentX96,
                liquidity,
                amountRemainingLessFee,
                zeroForOne
            );
        bool max = sqrtPriceNextX96 == sqrtPriceTargetX96;
        //计算输入输出的数量
        if (zeroForOne) {
            amountIn = max ? amountIn :  Math.calcAmount0Delta(
                sqrtPriceCurrentX96,
                sqrtPriceNextX96,
                liquidity,
                true
            );
            amountOut = Math.calcAmount1Delta(
            sqrtPriceCurrentX96,
            sqrtPriceNextX96,
            liquidity,
            false
        );
        }else{
            amountIn = max
                ? amountIn
                : Math.calcAmount1Delta(
                    sqrtPriceCurrentX96,
                    sqrtPriceNextX96,
                    liquidity,
                    true
                );
            amountOut = Math.calcAmount0Delta(
                sqrtPriceCurrentX96,
                sqrtPriceNextX96,
                liquidity,
                false
            );
        }
        /**如果没有达到上界，现在的价格区间有足够的流动性来填满交易，
        因此我们只需要返回填满交易所需数量与实际数量之间的差即可。 */
        if (!max) {
            feeAmount = amountRemaining - amountIn;
        } else {
            feeAmount = Math.mulDivRoundingUp(amountIn, fee, 1e6 - fee);
        }
        
        // //如果交易方向相反，则交换token
        // if (!zeroForOne) {
        //     (amountIn, amountOut) = (amountOut, amountIn);
        }
    }
}
