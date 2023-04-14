// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

import "./interfaces/IUniswapV3Pool.sol";
import "./lib/Path.sol";
import "./lib/PoolAddress.sol";
import "./lib/TickMath.sol";

contract UniswapV3Quoter {
    using Path for bytes;
    struct QuoteSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        uint256 amountIn;
        uint160 sqrtPriceLimitX96;
        // address pool;
        // uint256 amountIn;
        // bool zeroForOne;
    }
    address public immutable factory;

    constructor(address factory_) {
        factory = factory_;
    }

    function quoteSingle(
        QuoteSingleParams memory params
    )
        public
        returns (uint256 amountOut, uint160 sqrtPriceX96After, int24 tickAfter)
    {
        IUniswapV3Pool pool = getPool(
            params.tokenIn,
            params.tokenOut,
            params.fee
        );

        bool zeroForOne = params.tokenIn < params.tokenOut;

        try
            pool.swap(
                address(this),
                zeroForOne,
                params.amountIn,
                params.sqrtPriceLimitX96 == 0
                    ? (
                        zeroForOne
                            ? TickMath.MIN_SQRT_RATIO + 1
                            : TickMath.MAX_SQRT_RATIO - 1
                    )
                    : params.sqrtPriceLimitX96,
                abi.encode(address(pool))
            )
        {} catch (bytes memory reason) {
            return abi.decode(reason, (uint256, uint160, int24));
        }
    }

    //多池子报价
    /**获取当前池子参数；
    在当前池子中调用 quoteSingle；
    保存返回值；
    重复直到路径中没有池子，然后返回。 */
    function quote(
        bytes memory path,
        uint256 amountIn
    )
        public
        returns (
            //模拟真实合约交易的过程，然后revert掉
            //QuoteParams memory params
            uint256 amountOut,
            uint160[] sqrtPriceX96AfterList,
            int24[] tickAfterList
        )
    {
        sqrtPriceX96AfterList = new uint160[](path.numPools());
        tickAfterList = new int24[](path.numPools());

        uint256 i = 0;
        while (true) {
            (address tokenIn, address tokenOut, uint24 fee) = path
                .decodeFirstPool();

            (
                uint256 amountOut_,
                uint160 sqrtPriceX96After,
                int24 tickAfter
            ) = quoteSingle(
                    QuoteSingleParams({
                        tokenIn: tokenIn,
                        tokenOut: tokenOut,
                        fee: fee,
                        amountIn: amountIn,
                        sqrtPriceLimitX96: 0
                    })
                );

            sqrtPriceX96AfterList[i] = sqrtPriceX96After;
            tickAfterList[i] = tickAfter;
            amountIn = amountOut_;
            i++;

            if (path.hasMultiplePools()) {
                path = path.skipToken();
            } else {
                amountOut = amountIn;
                break;
            }
        }
        // try
        //     //注意这种接口的写法 初始化真正的交易
        //     IUniswapV3Pool(params.pool).swap(
        //         address(this),
        //         params.zeroForOne,
        //         params.amountIn,
        //         params.sqrtPriceLimitX96 == 0
        //             ? (
        //                 params.zeroForOne
        //                     ? TickMath.MIN_SQRT_RATIO + 1
        //                     : TickMath.MAX_SQRT_RATIO - 1
        //             )
        //             : params.sqrtPriceLimitX96,
        //         abi.encode(params.pool)
        //     )
        // {} catch (bytes memory reason) {
        //     //对应的reason解码返回
        //     return abi.decode(reason, (uint256, uint160, int24));
        // }
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes memory data
    ) external view {
        address pool = abi.decode(data, (address));

        uint256 amountOut = amount0Delta > 0
            ? uint256(-amount1Delta)
            : uint256(-amount0Delta);

        (uint160 sqrtPriceX96After, int24 tickAfter, , , ) = IUniswapV3Pool(
            pool
        ).slot0();

        assembly {
            let ptr := mload(0x40)
            mstore(ptr, amountOut)
            mstore(add(ptr, 0x20), sqrtPriceX96After)
            mstore(add(ptr, 0x40), tickAfter)
            revert(ptr, 96)
        }
    }

    function getPool(
        address token0,
        address token1,
        uint24 fee
    ) internal view returns (IUniswapV3Pool pool) {
        (token0, token1) = token0 < token1
            ? (token0, token1)
            : (token1, token0);
        pool = IUniswapV3Pool(
            PoolAddress.computeAddress(factory, token0, token1, fee)
        );
    }
}
