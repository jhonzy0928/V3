// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

library Tick {
    struct Info {
        bool initialized;
        uint128 liquidity;
    }
    //返回一个 flipped flag，当流动性被添加到一个空的 tick 或整个 tick 的流动性被耗尽时为 true。
    function update(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        uint128 liquidityDelta
    ) internal returns(bool flipped){
        Tick.Info storage tickInfo = self[tick];
        uint128 liquidityBefore = tickInfo.liquidity;
        uint128 liquidityAfter = liquidityBefore + liquidityDelta;

        flipped = (liquidityAfter == 0) != (liquidityBefore == 0);

        if (liquidityBefore == 0) {
            tickInfo.initialized = true;
        }

        tickInfo.liquidity = liquidityAfter;
    }
}
