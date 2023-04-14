//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "./lib/LiquidityMath.sol";
import "./lib/Position.sol";
import "./lib/Math.sol";
import "./lib/SwapMath.sol";
import "./lib/Tick.sol";
import "./lib/TickBitmap.sol";
import "./lib/TickMath.sol";
import "./lib/FixedPoint128.sol";
import "./lib/Oracle.sol";

import "./prb/Common.sol";

import "./interfaces/IUniswapV3Pool.sol";
import "./interfaces/IUniswapV3PoolDeployer.sol";
import "./interfaces/IUniswapV3MintCallback.sol";
import "./interfaces/IUniswapV3SwapCallback.sol";
import "./interfaces/IUniswapV3FlashCallback.sol";
import "./interfaces/IERC20.sol";

contract UniswapV3Pool is IUniswapV3Pool {
    //用合约库来初始化
    //using A for B 是Solidity的一个语言特性，能够让你用库合约 A 中的函数来扩展类型 B(数据结构？)
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    using Oracle for Oracle.Observation[65535];
    /**观测存储在一个定长的数组里，当一个新的观测被存储并且 observationCardinalityNext 
    超过 observationCardinality 的时候就会扩展。如果一个数组不能被扩展（下一个基数与现在的基数相同），
    旧的观测就会被覆盖，例如一个观测存储在下标 0，
    下一个就存储在下标 1，以此类推。 */

    error AlreadyInitialized();
    error InvalidTickRange();
    error NotEnoughLiquidity();
    error ZeroLiquidity();
    error InsufficientInputAmount();
    error transferFailed();
    error InvalidPriceLimit();

    event Flash(address indexed recipient, uint256 amount0, uint256 amount1);
    event Burn(
        address indexed owner,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );
    event Collect(
        address indexed owner,
        address recipient,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint256 amount0,
        uint256 amount1
    );
    event Mint(
        address sender,
        address indexed owner,
        int24 indexed lowerTick,
        int24 indexed upperTick,
        uint128 amount,
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
    mapping(int16 => uint256) public tickBitmap;
    //mapping(address => uint256) private _balances;
    uint128 public liquidity;

    mapping(int24 => Tick.Info) public ticks;
    mapping(bytes32 => Position.Info) public positions;

    uint256 public feeGrowthGlobal0X128; //每单位的全局手续费
    uint256 public feeGrowthGlobal1X128; //每单位虚拟流动性所赚取的费用总额,

    //pool tokens immutable and parameters
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable tickSpacing;
    uint24 public immutable fee;

    struct SwapState {
        //SwapState 维护了当前 swap 的状态。
        uint256 amountSpecifiedRemaining; //amoutSpecifiedRemaining 跟踪了还需要从池子中获取的 token 数量：当这个数量为 0 时，这笔订单就被填满了。
        uint256 amountCalculated; //amountCalculated 是由合约计算出的输出数量。
        uint160 sqrtPriceX96; //sqrtPriceX96 和 tick 是交易结束后的价格和 tick。
        int24 tick;
        uint256 feeGrowthGlobalX128;
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
        uint256 feeAmount; //交易费总量
    }

    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
        // Most recent observation index
        uint16 observationIndex;
        // Maximum number of observations
        uint16 observationCardinality;
        // Next maximum number of observations
        uint16 observationCardinalityNext;
    }
    Slot0 public slot0;

    /*在构造函数中，我们初始化了不可变的 token 地址、现在的价格和对应的 tick。
    // constructor(
    //     address token0_,
    //     address token1_,
    //     uint160 sqrtPriceX96,
    //     int24 tick
    // ) {
    //     token0 = token0_;
    //     token1 = token1_;

    //     slot0 = Slot0({sqrtPriceX96: sqrtPriceX96, tick: tick});
     }*/
    //加入工厂合约之后的变化
    constructor() {
        (factory, token0, token1, tickSpacing, fee) = IUniswapV3PoolDeployer(
            msg.sender
        ).parameters();
    }

    function initialize(uint160 sqrtPriceX96) public {
        if (slot0.sqrtPriceX96 != 0) revert AlreadyInitialized();
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);
        (uint16 cardinality, uint cardinalityNext) = observation.initialize(
            _blockTimestamp()
        );
        //跟踪现在的价格和对应的tick等，存储在slot中来节省gas费
        slot0 = Slot0({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            observationIndex: 0,
            observationCardinality: cardinality,
            observationCardinalityNext: cardinalityNext
        });
    }

    //把限价单等内容抽出来 根据区间提供流动性
    struct ModifyPositionParams {
        address owner;
        int24 lowerTick;
        int24 upperTick;
        int128 liquidityDelta;
    }

    function _modifyPosition(
        ModifyPositionParams memory params
    )
        internal
        returns (Position.Info storage position, int256 amount0, int256 amount1)
    {
        //节省gasfee
        Slot0 memory slot0_ = slot0;
        uint256 feeGrowthGlobal0X128_ = feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128_ = feeGrowthGlobal1X128;
        position = positions.get(
            params.owner,
            params.lowerTick,
            params.upperTick
        );
        //添加tick和position信息
        // 如果一个 tick 第一次被引用，或者移除了所有引用
        //当流动性被添加到一个空的 tick 或整个 tick 的流动性被耗尽时为 下届为true。
        // 那么更新 tick 位图
        bool flippedLower = ticks.update(
            params.lowerTick,
            slot0_.tick,
            int128(params.liquidityDelta),
            feeGrowthGlobal0X128_,
            feeGrowthGlobal1X128_,
            // int128(amount),//希望提供的流动性的数量
            false
        );
        bool flippedUpper = ticks.update(
            params.upperTick,
            slot0_.tick,
            int128(params.liquidityDelta),
            feeGrowthGlobal0X128_,
            feeGrowthGlobal1X128_,
            true
        );
        //传入tick和TickSpacing
        if (flippedLower) {
            //设置上下届
            tickBitmap.flipTick(lowerTick, int24(tickSpacing));
        }
        if (flippedUpper) {
            tickBitmap.flipTick(upperTick, int24(tickSpacing));
        }
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = ticks
            .getFeeGrowthInside(
                params.lowerTick,
                params.upperTick,
                slot0_.tick,
                feeGrowthGlobal0X128_,
                feeGrowthGlobal1X128_
            );
        position.update(
            params.liquidityDelta,
            feeGrowthInside0X128,
            feeGrowthInside1X128
        );
        //当当前价格不在价格区间内时，形成限价单
        //整个区间都是 dertX
        if (slot0_.tick < params.lowerTick) {
            //muldiv是x*y/z div是x/y
            amount0 = Math.calcAmount0Delta(
                TickMath.getSqrtRatioAtTick(params.lowerTick),
                TickMath.getSqrtRatioAtTick(params.upperTick),
                params.liquidityDelta
            );
        } else if (slot0_.tick < params.upperTick) {
            amount0 = Math.calcAmount0Delta(
                // TickMath.getSqrtRatioAtTick(slot0_.tick),
                slot0_.sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(params.upperTick),
                params.liquidityDelta
            );

            amount1 = Math.calcAmount1Delta(
                // TickMath.getSqrtRatioAtTick(slot0_.tick),
                slot0_.sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(params.lowerTick),
                params.liquidityDelta
            );
            liquidity = LiquidityMath.addLiquidity(liquidity, int128(amount)); //当移除流动性时金额为负
        } else {
            amount1 = Math.calcAmount1Delta(
                TickMath.getSqrtRatioAtTick(params.lowerTick),
                TickMath.getSqrtRatioAtTick(params.upperTick),
                params.liquidityDelta
            );
        }
    }

    function mint(
        address owner, //token 所有者的地址，来识别是谁提供的流动性
        int24 lowerTick, //上界和下界的 tick，来设置价格区间的边界；
        int24 upperTick,
        uint128 amount, //希望提供的流动性的数量
        bytes calldata data //传入不会被函数本身使用的函数
    ) external returns (uint256 amount0, uint256 amount1) {
        if (
            lowerTick >= upperTick ||
            lowerTick < TickMath.MIN_TICK ||
            upperTick > TickMath.MAX_TICK
        ) revert InvalidTickRange();
        if (amount == 0) revert ZeroLiquidity();
        (, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: owner,
                lowerTick: lowerTick,
                upperTick: upperTick,
                liquidityDelta: int128(amount)
            })
        );
        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);
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

    //mint的相反数 添加负的流动性
    function burn(
        int24 lowerTick,
        int24 upperTick,
        uint128 amount
    ) public returns (uint256 amount0, uint256 amount1) {
        (
            Position.Info storage position,
            int256 amount0Int,
            int256 amount1Int
        ) = _modifyPosition(
                ModifyPositionParams({
                    owner: msg.sender,
                    lowerTick: lowerTick,
                    upperTick: upperTick,
                    liquidityDelta: -(int128(amount))
                })
            );

        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        if (amount0 > 0 || amount1 > 0) {
            (position.tokensOwed0, position.tokensOwed1) = (
                position.tokensOwed0 + uint128(amount0),
                position.tokensOwed1 + uint128(amount1)
            );
            /**
            更新这个 position 应得的 token 数量——它包含提供流动性时转入的 token 数量以及费用收入。
            我们也可以把它看做把 position 流动性转换到 token的过程——
            这些 token 将不会再被用于流动性 */
        }

        emit Burn(msg.sender, lowerTick, upperTick, amount, amount0, amount1);
    }

    //这个函数仅仅是从池子中转出 token，
    //并确保只能转出有效的数量（不能够转出超过燃烧+小费收入的数量）。
    function collect(
        address recipient,
        int24 lowerTick,
        int24 upperTick,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) public returns (uint128 amount0, uint128 amount1) {
        Position.Info memory position = positions.get(
            msg.sender,
            lowerTick,
            upperTick
        );
        //从区间记录的token中 token与手续费关联
        /**
        根据 position 中已经记录的手续费和用户请求的数额，
        发送指定数额的手续费给用户。
         */
        amount0 = amount0Requested > position.tokensOwed0
            ? position.tokensOwed0
            : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1
            ? position.tokensOwed1
            : amount1Requested;

        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            IERC20(token0).transfer(recipient, amount0);
        }

        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            IERC20(token1).transfer(recipient, amount1);
        }

        emit Collect(
            msg.sender,
            recipient,
            lowerTick,
            upperTick,
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
        //用缓存缓存gas费
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
            feeGrowthGlobalX128: zeroForOne
                ? feeGrowthGlobal0X128
                : feeGrowthGlobal1X128,
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
                // 1,
                int24(tickSpacing),
                zeroForOne
            );
            //根据sqrtP与tick的关系
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.nextTick);
            //接下来，我们计算当前价格区间能够提供的流动性的数量，以及交易达到的目标价格L dertaX
            (
                state.sqrtPriceX96,
                step.amountIn,
                step.amountOut,
                step.feeAmount
            ) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                //这块没搞懂 反正取较大值 在一步交易中 如果这个区间提供的dertaX够了 target价格就是较大值
                (
                    zeroForOne
                        ? step.sqrtPriceNextX96 < sqrtPriceLimitX96
                        : step.sqrtPriceNextX96 > sqrtPriceLimitX96
                )
                    ? sqrtPriceLimitX96
                    : step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining,
                fee
            );
            //循环中的最后一步就是更新SwapState。step.amountIn 是这个价格区间可以从用户手中买走的token数量了；step.amountOut 是相应的池子卖给用户的数量。
            //state.sqrtPriceX96 是交易结束后的现价（因为交易会改变价格）
            //减去手续费
            state.amountSpecifiedRemaining -= step.amountIn + step.feeAmount;
            state.amountCalculated += step.amountOut;
            //fg=feeAmount/L
            if (state.liquidity > 0) {
                state.feeGrowthGlobalX128 += mulDiv(
                    step.feeAmount,
                    FixedPoint128.Q128,
                    state.liquidity
                );
            }

            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                //更新了的价格到了下一个区间
                //state.sqrtPriceX96 是新的现价，即在上一个交易过后会被设置的价格；
                //step.sqrtNextX96 是下一个已初始化的 tick 对应的价格。
                //如果它们相等，说明我们达到了这个区间的边界。
                int128 liquidityDelta = ticks.cross(
                    step.nextTick,
                    (
                        zeroForOne
                            ? state.feeGrowthGlobalX128
                            : feeGrowthGlobal0X128
                    ),
                    (
                        zeroForOne
                            ? feeGrowthGlobal1X128
                            : state.feeGrowthGlobalX128
                    )
                );
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
        //更新 跟踪的价格
        if (state.tick != slot0_.tick) {
            //更新预言机 当现价改变时，一个观测会被写入观测数组
            (
                uint16 observationIndex,
                uint16 observationCardinality
            ) = observations.write(
                    slot0_.observationIndex,
                    _blockTimestamp(),
                    slot0_.tick,
                    slot0_.observationCardinality,
                    slot0_.observationCardinalityNext
                );
            // (slot0.sqrtPriceX96, slot0.tick) = (state.sqrtPriceX96, state.tick);
            (
                slot0.sqrtPriceX96,
                slot0.tick,
                slot0.observationIndex,
                slot0.observationCardinality
            ) = (
                state.sqrtPriceX96,
                state.tick,
                observationIndex,
                observationCardinality
            );
        }
        if (liquidity_ != state.liquidity) liquidity = state.liquidity;
        //更新fg
        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
        }

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
        uint256 fee0 = Math.mulDivRoundingUp(amount0, fee, 1e6);
        uint256 fee1 = Math.mulDivRoundingUp(amount1, fee, 1e6);

        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));

        if (amount0 > 0) IERC20(token0).transfer(msg.sender, amount0);
        if (amount1 > 0) IERC20(token1).transfer(msg.sender, amount1);

        IUniswapV3FlashCallback(msg.sender).uniswapV3FlashCallback(
            fee0,
            fee1,
            data
        );

        require(
            IERC20(token0).balanceOf(address(this)) >= balance0Before + fee0
        );

        require(
            IERC20(token1).balanceOf(address(this)) >= balance1Before + fee1
        );

        emit Flash(msg.sender, amount0, amount1);
    }

    /**
    并不是每个区块都保证存在观测，因为交易并不一定在每个区块中都有。
    因此，会存在一些区块我们不知道价格，并且这样缺失的观测可能会很多。
    当然，我们并不希望在我们预言机提供的价格之间有很大空缺，
    这也是我们为什么使用时间加权平均价格（TWAP）——
    这样我们可以在没有观测的地方使用平均价格。
    TWAP 让我们能够做价格插值，即在两个观测之间画一条线，
    每个在这条线上的点都是两个观测之间某个时间戳对应的价格。
     */
    /**
    读取观测意味着通过时间戳寻找到观测，并且在确实的观测处插值，
    同时要考虑到观测数组是可以溢出的（即数组中最老的观测可以在最新的观测之后）。
    由于我们并不是用时间戳作为下标来索引观测（为了节省 gas），
    我们需要使用二分查找算法来更有效地查找。
     */
    function observe(
        uint32[] calldata secondsAgos
    ) public view returns (int56[] memory tickCumulatives) {
        return
            observations.observe(
                _blockTimestamp(),
                secondsAgos,
                slot0.tick,
                slot0.observationIndex,
                slot0.observationCardinality
            );
    }

    /**扩展一个池子中观测的基数（数组扩容），并为此支付 gas */
    function increaseObservationCardinalityNext(
        uint16 observationCardinalityNext
    ) public {
        uint16 observationCardinalityNextOld = slot0.observationCardinalityNext;
        uint16 observationCardinalityNextNew = observations.grow(
            observationCardinalityNextOld,
            observationCardinalityNext
        );

        if (observationCardinalityNextNew != observationCardinalityNextOld) {
            slot0.observationCardinalityNext = observationCardinalityNextNew;
            emit IncreaseObservationCardinalityNext(
                observationCardinalityNextOld,
                observationCardinalityNextNew
            );
        }
    }

    function balance0() internal returns (uint256 balance) {
        balance = IERC20(token0).balanceOf(address(this));
    }

    function balance1() internal returns (uint256 balance) {
        balance = IERC20(token1).balanceOf(address(this));
    }

    function _blockTimestamp() internal view returns (uint32 timestamp) {
        timestamp = uint32(block.timestamp);
        //每个块的时间戳
    }
}
