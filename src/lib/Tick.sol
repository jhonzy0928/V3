// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import "./LiquidityMath.sol";
import "./Math.sol";

library Tick {
    struct Info {
        bool initialized;
        uint128 liquidityGross; //跟踪一个tick拥有的绝对流动性数量。它用来跟踪一个 tick 是否还可用。
        int128 liquidityNet; //是一个有符号整数，用来跟踪当跨越 tick 时添加/移除的流动性数量。
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
        //外侧的手续费
    }

    //返回一个 flipped flag，当流动性被添加到一个空的 tick 或整个 tick 的流动性被耗尽时为 true。
    function update(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        int24 currentTick,
        int128 liquidityDelta,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        bool upper
    ) internal returns (bool flipped) {
        //返回一个 flipped flag，当流动性被添加到一个空的 tick 或整个 tick 的流动性被耗尽时为 true。
        Tick.Info storage tickInfo = self[tick];
        uint128 liquidityBefore = tickInfo.liquidityGross;
        uint128 liquidityAfter = LiquidityMath.addLiquidity(
            liquidityBefore,
            liquidityDelta
        );

        flipped = (liquidityAfter == 0) != (liquidityBefore == 0);

        if (liquidityBefore == 0) {
            if (tick <= currentTick) {
                tickInfo.feeGrowthOutside0X128 = feeGrowthGlobal0X128;
                tickInfo.feeGrowthOutside1X128 = feeGrowthGlobal1X128;
            }
            //在current tick之外 外侧手续费均已收取
            tickInfo.initialized = true;
        }

        tickInfo.liquidityGross = liquidityAfter;
        tickInfo.liquidityNet = upper //穿越tick L=L+dertaL
            ? int128(int256(tickInfo.liquidityNet) - liquidityDelta)
            : int128(int256(tickInfo.liquidityNet) + liquidityDelta);
    }

    function cross(
        //穿过tick时 返回dertaL
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) internal returns (int128 liquidityDelta) {
        Tick.Info storage info = self[tick];
        //穿过tick时 更新fo=fg-fo
        /**
        tick 跟踪在它之外累积的费用。
         */
        /**
        在发生交易时，当前价格的 ic 是会不断变化的。
        因此，当 ic 和 i 的位置关系发生了变化时，
        我们需要更新 fo(i) 的值。 具体来说，
        当前价格穿过某一个 tick 时，
        需要更新此 tick 上的 fo(i)，
        更新的方式时将其值修改为另一侧的手续费总和
         */
        /**
         这个 tick 之外积累的总费用减去上一次被穿过时
         第一次穿过和第二次穿过 中间就是外侧累积的费用
         这个 tick 记录的费用。 */
        /**
         tick 知道了在他之外累积了多少费用，就可以让我们计算出在一个 position 内部累积了多少费用（position 就是两个 tick 之间的区间）。
        知道了一个 position 内部累积了多少费用，我们就能够计算 LP 能够分成到多少费用。如果一个 position 没有参与到交易中，它的累计费率会是 0，
        在这个区间提供流动性的 LP 将不会获得任何利润。
          */
        info.feeGrowthOutside0X128 =
            feeGrowthGlobal0X128 -
            info.feeGrowthOutside0X128;
        info.feeGrowthOutside1X128 =
            feeGrowthGlobal1X128 -
            info.feeGrowthOutside1X128;
        liquidityDelta = info.liquidityNet;
    }

    //区间内手续费f=fg-fa-fb
    function getFeeGrowthInside(
        mapping(int24 => Tick.Info) storage self,
        int24 lowerTick_,
        int24 upperTick_,
        int24 currentTick,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    )
        internal
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        Tick.Info storage lowerTick = self[lowerTick_];
        Tick.Info storage upperTick = self[upperTick_];

        uint256 feeGrowthBelow0X128;
        uint256 feeGrowthBelow1X128;
        if (currentTick >= lowerTick_) {
            feeGrowthBelow0X128 = lowerTick.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = lowerTick.feeGrowthOutside1X128;
        } else {
            feeGrowthBelow0X128 =
                feeGrowthGlobal0X128 -
                lowerTick.feeGrowthOutside0X128;
            feeGrowthBelow1X128 =
                feeGrowthGlobal1X128 -
                lowerTick.feeGrowthOutside1X128;
        }

        uint256 feeGrowthAbove0X128;
        uint256 feeGrowthAbove1X128;
        if (currentTick < upperTick_) {
            feeGrowthAbove0X128 = upperTick.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = upperTick.feeGrowthOutside1X128;
        } else {
            feeGrowthAbove0X128 =
                feeGrowthGlobal0X128 -
                upperTick.feeGrowthOutside0X128;
            feeGrowthAbove1X128 =
                feeGrowthGlobal1X128 -
                upperTick.feeGrowthOutside1X128;
        }

        feeGrowthInside0X128 =
            feeGrowthGlobal0X128 -
            feeGrowthBelow0X128 -
            feeGrowthAbove0X128;
        feeGrowthInside1X128 =
            feeGrowthGlobal1X128 -
            feeGrowthBelow1X128 -
            feeGrowthAbove1X128;
    }
}
