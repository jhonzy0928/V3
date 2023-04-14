// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

interface IUniswapV3Manager {
    struct MintParams {
        address poolAddress;
        int24 lowerTick;
        int24 upperTick;
        uint256 amount0Desired; //希望铸造的token
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
    }
    struct GetPositionParams {
        address tokenA;
        address tokenB;
        uint24 fee;
        address owner;
        int24 lowerTick;
        int24 upperTick;
    }
    struct SwapSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        uint256 amountIn;
        uint160 sqrtPriceLimitX96;
    }
    /*
    SwapSingleParams 的参数为池子参数、输入数量，
    以及一个限制价格——这与我们之前的基本一致。
    注意到，我们不再需要 data 字段。
    */
    struct SwapParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 minAmountOut;
    }
    /*SwapParams 的参数为路径、输出金额接受方、输入数量，
    以及最小输出数量。
    最后一个参数替代了 sqrtPriceLimitX96，
    因为在多池子交易中我们不再能使用池子合约中的滑点保护了
    （使用限价机制实现）。我们需要另实现一个滑点保护，
    检查最终的输出数量并且与 minAmountOut 对比：
    当最终输出数量小于 minAmountOut 的时候交易会失败。
    */
    struct SwapCallbackData {
        bytes path;
        address payer;
    }
    /*path 是交易路径，
    payer 是在这笔交易中付出 token 的地址——
    在多池交易中这个付款者会有所不同。*/
}
