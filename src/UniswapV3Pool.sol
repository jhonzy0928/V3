//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;
import "./lib/Math.sol";
import "./lib/LiquidityMath.sol";
import "./lib/Position.sol";
import "./lib/Math.sol";
import "./lib/SwapMath.sol";
import "./lib/Tick.sol";
import "./lib/TickBitmap.sol";
import "./lib/TickMath.sol";

import "./interfaces/IUniswapV3Pool.sol";
import "./interfaces/IUniswapV3MintCallback.sol";
import "./interfaces/IUniswapV3SwapCallback.sol";
import "./interfaces/IUniswapV3FlashCallback.sol";
import "./interfaces/IERC20.sol";

contract UniswapV3Pool {
    //用合约库来初始化
    //using A for B 是Solidity的一个语言特性，能够让你用库合约 A 中的函数来扩展类型 B(数据结构？)
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;

    mapping(int16 => uint256) public tickBitmap;
    mapping(address => uint256) private _balances;
    uint128 public liquidity;

    mapping(int24 => Tick.Info) public ticks;
    mapping(bytes32 => Position.Info) public positions;

    error InvalidPriceLimit();
    error InvalidTickRange();
    error NotEnoughLiquidity();
    error ZeroLiquidity();
    error InsufficientInputAmount();
    error transferFailed();

    event Flash(address indexed recipient, uint256 amount0, uint256 amount1);

    event Mint(
        address sender,
        address indexed owner,
        int24 indexed lowerTick,
        int24 indexed upperTick,
        uint256 amount,
        uint256 amount0,
        uint256 amount1
    );
    event Swap(
        address indexed sender,
        address indexed recipient,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    );

    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = -MIN_TICK;

    //pool tokens immutable
    address public immutable token0;
    address public immutable token1;

    struct SwapState {
        //SwapState 维护了当前 swap 的状态。
        uint256 amountSpecifiedRemaining; //amoutSpecifiedRemaining 跟踪了还需要从池子中获取的 token 数量：当这个数量为 0 时，这笔订单就被填满了。
        uint256 amountCalculated; //amountCalculated 是由合约计算出的输出数量。
        uint160 sqrtPriceX96; //sqrtPriceX96 和 tick 是交易结束后的价格和 tick。
        int24 tick;
        uint128 liquidity;
    }

    struct StepState {
        //StepState 维护了当前交易“一步”的状态。这个结构体跟踪“填满订单”过程中一个循环的状态。
        uint160 sqrtPriceStartX96; //sqrtPriceStartX96 跟踪循环开始时的价格
        int24 nextTick; //nextTick 是能够为交易提供流动性的下一个已初始化的tick
        bool initialized;
        uint160 sqrtPriceNextX96; //sqrtPriceNextX96 是下一个 tick 的价格
        uint256 amountIn;
        uint256 amountOut;
    }

    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
    }
    Slot0 public slot0;

    //在构造函数中，我们初始化了不可变的 token 地址、现在的价格和对应的 tick。
    constructor(
        address token0_,
        address token1_,
        uint160 sqrtPriceX96,
        int24 tick
    ) {
        token0 = token0_;
        token1 = token1_;

        slot0 = Slot0({sqrtPriceX96: sqrtPriceX96, tick: tick});
    }

    // function balance0() private view returns (uint256) {
    //     (bool success, bytes memory data) = token0.staticcall(
    //         abi.encodeWithSelector(IERC20.balanceOf.selector, address(this))
    //     );
    //     require(success && data.length >= 32);
    //     return abi.decode(data, (uint256));
    // }

    // function balance1() private view returns (uint256) {
    //     (bool success, bytes memory data) = token1.staticcall(
    //         abi.encodeWithSelector(IERC20.balanceOf.selector, address(this))
    //     );
    //     require(success && data.length >= 32);
    //     return abi.decode(data, (uint256));
    // }

    // function _safeTransfer(address token, address to, uint256 value) private {
    //     //可以调用其他合约函数
    //     (bool success, bytes memory data) = token.call(
    //         abi.encodeWithSignature("transfer(address,uint256)", to, value)
    //     );
    //     if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
    //         revert transferFailed();
    //     }
    // }

    function mint(
        address owner, //token 所有者的地址，来识别是谁提供的流动性
        int24 lowerTick, //上界和下界的 tick，来设置价格区间的边界；
        int24 upperTick,
        uint128 amount, //希望提供的流动性的数量
        bytes calldata data //传入不会被函数本身使用的函数
    ) external returns (uint256 amount0, uint256 amount1) {
        if (
            lowerTick >= upperTick ||
            lowerTick < MIN_TICK ||
            upperTick > MAX_TICK
        ) revert InvalidTickRange();
        if (amount == 0) revert ZeroLiquidity();
        //添加tick和position信息
        bool flippedLower = ticks.update(lowerTick, int128(amount), false);
        bool flippedUpper = ticks.update(upperTick, int128(amount), true);
        //传入tick和TickSpacing始终为1
        if (flippedLower) {
            tickBitmap.flipTick(lowerTick, 1);
        }
        if (flippedUpper) {
            tickBitmap.flipTick(upperTick, 1);
        }

        Position.Info storage position = positions.get(
            owner,
            lowerTick,
            upperTick
        );
        position.update(amount);
        Slot0 memory slot0_ = slot0;
        //当当前价格不在价格区间内时，形成限价单
        if (slot0_.tick < lowerTick) {
            amount0 = Math.calcAmount0Delta(
                TickMath.getSqrtRatioAtTick(slot0_.tick),
                TickMath.getSqrtRatioAtTick(upperTick),
                amount
            );
        } else if (slot0_.tick < upperTick) {
            amount0 = Math.calcAmount0Delta(
                TickMath.getSqrtRatioAtTick(slot0_.tick),
                TickMath.getSqrtRatioAtTick(upperTick),
                amount
            );

            amount1 = Math.calcAmount1Delta(
                TickMath.getSqrtRatioAtTick(slot0_.tick),
                TickMath.getSqrtRatioAtTick(lowerTick),
                amount
            );
            liquidity = LiquidityMath.addLiquidity(liquidity, int128(amount)); //当移除流动性时金额为负
        } else {
            amount1 = Math.calcAmount1Delta(
                TickMath.getSqrtRatioAtTick(slot0_.tick),
                TickMath.getSqrtRatioAtTick(lowerTick),
                amount
            );
        }

        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();
        //这个callback为啥会在外面实现 是因为带了callback特殊？
        //初始化之后可以由外部合约继承实现callback函数
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(
            amount0,
            amount1,
            data
        );
        if (amount0 > 0 && balance0Before + amount0 > balance0())
            revert InsufficientInputAmount();
        if (amount1 > 0 && balance1Before + amount1 > balance1())
            revert InsufficientInputAmount();
        emit Mint(
            msg.sender,
            owner,
            lowerTick,
            upperTick,
            amount,
            amount0,
            amount1
        );
    }

    //recipient==提出token的接受者
    function swap(
        address recipient,
        bool zeroForOne, //zeroForOne 是用来控制交易方向的 flag：当设置为 true，是用 token0 兑换 token1；false 则相反。
        uint256 amountSpecified, //amountSpecified 是用户希望卖出的 token 数量。
        uint160 sqrtPriceLimitX96, //用户希望设置的停机价格
        bytes calldata data
    ) public returns (int256 amount0, int256 amount1) {
        Slot0 memory slot0_ = slot0;
        uint128 liquidity_ = liquidity;
        //不超过用户期望
        if (
            zeroForOne
                ? sqrtPriceLimitX96 > slot0_.sqrtPriceX96 ||
                    sqrtPriceLimitX96 < TickMath.MIN_SQRT_RATIO
                : sqrtPriceLimitX96 < slot0_.sqrtPriceX96 ||
                    sqrtPriceLimitX96 > TickMath.MAX_SQRT_RATIO
        ) revert InvalidPriceLimit();
        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0_.sqrtPriceX96,
            tick: slot0_.tick,
            liquidity: liquidity_
        });
        while (
            state.amountSpecifiedRemaining > 0 &&
            state.sqrtPriceX96 != sqrtPriceLimitX96
        ) {
            //在循环中，我们设置一个价格区间为这笔交易提供流动性的价格区间。
            //这个区间是从 state.sqrtPriceX96 到 step.sqrtPriceNextX96，
            //后者是下一个初始化的 tick 对应的价格（从上一章实现的 nextInitializedTickWithinOneWord 中获取）
            StepState memory step;

            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            (step.nextTick, ) = tickBitmap.nextInitializedTickWithinOneWord(
                state.tick,
                1,
                zeroForOne
            );
            //根据sqrtP与tick的关系
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.nextTick);
            //接下来，我们计算当前价格区间能够提供的流动性的数量，以及交易达到的目标价格L dertaX
            (state.sqrtPriceX96, step.amountIn, step.amountOut) = SwapMath
                .computeSwapStep(
                    state.sqrtPriceX96,
                    //这块没搞懂 反正取较大值
                    (
                        zeroForOne
                            ? step.sqrtPriceNextX96 < sqrtPriceLimitX96
                            : step.sqrtPriceNextX96 > sqrtPriceLimitX96
                    )
                        ? sqrtPriceLimitX96
                        : step.sqrtPriceNextX96,
                    state.liquidity,
                    state.amountSpecifiedRemaining
                );
            //循环中的最后一步就是更新SwapState。step.amountIn 是这个价格区间可以从用户手中买走的token数量了；step.amountOut 是相应的池子卖给用户的数量。
            //state.sqrtPriceX96 是交易结束后的现价（因为交易会改变价格）
            state.amountSpecifiedRemaining -= step.amountIn;
            state.amountCalculated += step.amountOut;
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                //更新了的价格到了下一个区间
                //state.sqrtPriceX96 是新的现价，即在上一个交易过后会被设置的价格；
                //step.sqrtNextX96 是下一个已初始化的 tick 对应的价格。
                //如果它们相等，说明我们达到了这个区间的边界。

                int128 liquidityDelta = ticks.cross(step.nextTick);
                if (zeroForOne) liquidityDelta = -liquidityDelta;
                state.liquidity = LiquidityMath.addLiquidity(
                    state.liquidity,
                    liquidityDelta
                );
                if (state.liquidity == 0) revert NotEnoughLiquidity();
                /*当更新 state.tick 时，如果价格是下降的（zeroForOne 设置为 true），
            我们需要将 tick 减一来走到下一个区间；而当价格上升时（zeroForOne 为 false），
            根据 TickBitmap.nextInitializedTickWithinOneWord，已经走到了下一个区间了。 */
                state.tick = zeroForOne ? step.nextTick - 1 : step.nextTick;
            } else if (state.sqrtPriceX96 != step.sqrtPriceNextX96) {
                //仍然在当前区间内
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }
        if (state.tick != slot0_.tick) {
            (slot0.sqrtPriceX96, slot0.tick) = (state.sqrtPriceX96, state.tick);
        }
        if (liquidity_ != state.liquidity) liquidity = state.liquidity;
        (amount0, amount1) = zeroForOne
            ? (
                //整体dertaX-Xremain>0, （没有填满）给用户发的B不够
                int256(amountSpecified - state.amountSpecifiedRemaining),
                -int256(state.amountCalculated)
            )
            : (
                -int256(state.amountCalculated),
                int256(amountSpecified - state.amountSpecifiedRemaining)
            );
        if (zeroForOne) {
            IERC20(token1).transfer(recipient, uint256(-amount1));
            uint256 balance0Before = balance0();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(
                amount0,
                amount1,
                data
            );
            //如果这个tick内dertaX不够满足到整个区间需要的dertaX
            //before+需要的dertaX 与before+用户发的dertaX相比 用户发少了 不信任用户
            if (balance0Before + uint256(amount0) > balance0())
                revert InsufficientInputAmount();
        } else {
            IERC20(token0).transfer(recipient, uint256(-amount0));
            uint256 balance1Before = balance1();
            //先在这里实例化，然后别的合约调用时 再去实现callback函数
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(
                amount0,
                amount1,
                data
            );
            //为啥源码是大于？ 实际需要传的和用户传的相比较
            if (balance1Before + uint256(amount1) > balance1())
                revert InsufficientInputAmount();
        }

        emit Swap(
            msg.sender,
            recipient,
            amount0,
            amount1,
            slot0.sqrtPriceX96,
            liquidity,
            slot0.tick
        );
    }

    function flash(
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) public {
        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));

        if (amount0 > 0) IERC20(token0).transfer(msg.sender, amount0);
        if (amount1 > 0) IERC20(token1).transfer(msg.sender, amount1);

        IUniswapV3FlashCallback(msg.sender).uniswapV3FlashCallback(data);

        require(IERC20(token0).balanceOf(address(this)) >= balance0Before);

        require(IERC20(token1).balanceOf(address(this)) >= balance1Before);

        emit Flash(msg.sender, amount0, amount1);
    }

    function balance0() internal returns (uint256 balance) {
        balance = IERC20(token0).balanceOf(address(this));
    }

    function balance1() internal returns (uint256 balance) {
        balance = IERC20(token1).balanceOf(address(this));
    }
}
