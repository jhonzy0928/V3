// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "./interfaces/IUniswapV3Manager.sol";
import "./interfaces/IUniswapV3Pool.sol";
import "./interfaces/IERC20.sol";

import "./lib/LiquidityMath.sol";
import "./lib/TickMath.sol";
import "./lib/PoolAddress.sol";
import "./lib/Path.sol";

contract UniswapV3Manager is IUniswapV3Manager {
    using Path for bytes;

    error SlippageCheckFailed(uint256 amount0, uint256 amount1);
    error TooLittleReceived(uint256 amountOut);

    address public immutable factory;

    constructor(address factory_) {
        factory = factory_;
    }

    function getPosition(
        GetPositionParams calldata params
    )
        public
        view
        returns (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        IUniswapV3Pool pool = getPool(params.tokenA, params.tokenB, params.fee);

        (
            liquidity,
            feeGrowthInside0LastX128,
            feeGrowthInside1LastX128,
            tokensOwed0,
            tokensOwed1
        ) = pool.positions(
            keccak256(
                abi.encodePacked(
                    params.owner,
                    params.lowerTick,
                    params.upperTick
                )
            )
        );
    }

    function mint(
        // address poolAddress_,
        // int24 lowerTick,
        // int24 upperTick,
        // uint128 liquidity,
        // bytes calldata data 把参数写在接口结构体一样
        MintParams calldata params
    ) public returns (uint256 amount0, uint256 amount1) {
        // return
        // UniswapV3Pool(poolAddress_).mint(
        //     msg.sender,
        //     lowerTick,
        //     upperTick,
        //     liquidity,
        //     data
        // );
        IUniswapV3Pool pool = IUniswapV3Pool(params.poolAddress);
        //现价
        (uint160 sqrtPriceX96, , , , ) = pool.slot0();
        //价格区间
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtRatioAtTick(
            params.lowerTick
        );
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtRatioAtTick(
            params.upperTick
        );
        uint128 Liquidity = LiquidityMath.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceLowerX96,
            sqrtPriceUpperX96,
            params.amount0Desired,
            params.amount1Desired
        );
        (amount0, amount1) = pool.mint(
            msg.sender,
            params.lowerTick,
            params.upperTick,
            Liquidity,
            abi.encode(
                IUniswapV3Pool.CallbackData({
                    token0: pool.token0(),
                    token1: pool.token1(),
                    payer: msg.sender
                })
            )
        );
        if (amount0 < params.amount0Min || amount1 < params.amount1Min)
            revert SlippageCheckFailed(amount0, amount1);
    }

    function swapSingle(
        SwapSingleParams calldata params
    ) public returns (uint256 amountOut) {
        amountOut = _swap(
            params.amountIn,
            msg.sender,
            params.sqrtPriceLimitX96,
            SwapCallbackData({
                path: abi.encodePacked(
                    params.tokenIn,
                    params.fee,
                    params.tokenOut
                ),
                payer: mag.sender
            })
        );
    }

    //多池子交易
    /*
    第一笔交易是由用户付费，因为用户提供最开始输入的 token。
    接下来，我们开始遍历路径中的池子：
    */
    function swap(
        // address poolAddress_,
        // bool zeroForOne,
        // uint256 amountSpecified,
        // uint160 sqrtPriceLimitX96,
        // bytes calldata data
        SwapParams memory params
    ) public returns (uint256 amountOut) {
        address payer = msg.sender;
        bool hasMultiplePools;
        while (true) {
            hasMultiplePools = params.path.hasMultiplePools();

            params.amountIn = _swap(
                params.amountIn,
                hasMultiplePools ? address(this) : params.recipient,
                0, //sqrtPriceLimitX96 设置为 0，来禁用池子合约中的滑点保护
                SwapCallbackData({
                    path: params.path.getFirstPool(),
                    payer: payer
                })
            );
            //完成一笔交易，前往下一个池子
            if (hasMultiplePools) {
                payer = address(this);
                params.path = params.path.skipToken();
            } else {
                amountOut = params.amountIn;
                break;
            }
        }
        // return
        //     IUniswapV3Pool(poolAddress_).swap(
        //         msg.sender,
        //         zeroForOne,
        //         amountSpecified,
        //         sqrtPriceLimitX96 == 0
        //             ? (
        //                 zeroForOne
        //                     ? TickMath.MIN_SQRT_RATIO + 1
        //                     : TickMath.MIN_SQRT_RATIO - 1
        //             )
        //             : sqrtPriceLimitX96,
        //         data
        //     );
        //新的滑点保护
        if (amountOut < params.minAmountOut)
            revert TooLittleReceived(amountOut);
    }

    //被单池和多池交易行函数调用
    function _swap(
        uint256 amountIn,
        address recipient,
        uint160 sqrtPriceLimitX96,
        SwapCallbackData memory data
    ) internal returns (uint256 amountOut) {
        //提取池子参数
        (address tokenIn, address tokenOut, uint24 tickSpacing) = data
            .path
            .decodeFirstPool();
        //确认交易方向
        bool zeroForOne = tokenIn < tokenOut;
        //执行交易
        (int256 amount0, int256 amount1) = getPool(
            tokenIn,
            tokenOut,
            tickSpacing
        ).swap(
                recipient,
                zeroForOne,
                amountIn,
                sqrtPriceLimitX96 == 0
                    ? (
                        zeroForOne
                            ? TickMath.MIN_SQRT_RATIO + 1
                            : TickMath.MAX_SQRT_RATIO - 1
                    )
                    : sqrtPriceLimitX96,
                abi.encode(data)
            );
        //找到哪个数量是对应的输出值
        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
    }

    //获取池子地址参数 解hash
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

    function uniswapV3MintCallback(
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) public {
        IUniswapV3Pool.CallbackData memory extra = abi.decode(
            data,
            (IUniswapV3Pool.CallbackData)
        );

        IERC20(extra.token0).transferFrom(extra.payer, msg.sender, amount0);
        IERC20(extra.token1).transferFrom(extra.payer, msg.sender, amount1);
    }

    function uniswapV3SwapCallback(
        int256 amount0,
        int256 amount1,
        bytes calldata data_
    ) public {
        SwapCallbackData memory data = abi.decode(data_, (SwapCallbackData));

        (address tokenIn, address tokenOut, ) = data.path.decodeFirstPool();

        bool zeroForOne = tokenIn < tokenOut;

        int256 amount = zeroForOne ? amount0 : amount1;

        /*如果付款人是当前合约（在连续交易时，当前合约作为中间人），
        它直接将本合约账户下的 token 转到下一个池子（调用这个 callback 的池子）。
        如果付款人是一个不同的地址（创建交易的用户），
        它从用户那里把 token 转给池子。 */
        if (data.payer == address(this)) {
            IERC20(tokenIn).transfer(msg.sender, uint256(amount));
        } else {
            IERC20(tokenIn).transferFrom(
                data.payer,
                msg.sender,
                uint256(amount)
            );
        }

        // IUniswapV3Pool.CallbackData memory extra = abi.decode(
        //     data,
        //     (IUniswapV3Pool.CallbackData)
        // );

        /*if (amount0 > 0) {
            IERC20(extra.token0).transferFrom(
                extra.payer,
                msg.sender,
                uint256(amount0)
            );
        }

        if (amount1 > 0) {
            IERC20(extra.token1).transferFrom(
                extra.payer,
                msg.sender,
                uint256(amount1)
            );
        }*/
    }
}
