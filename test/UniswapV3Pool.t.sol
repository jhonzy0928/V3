// test/UniswapV3Pool.t.sol
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "../lib/forge-std/src/Test.sol";
import "./ERC20Mintable.sol";
import "../src/UniswapV3Pool.sol";

contract UniswapV3PoolTest is Test {
    ERC20Mintable token0;
    ERC20Mintable token1;
    UniswapV3Pool pool;
    bool ShouldTransferInCallback;
    struct TestCaseParams {
        uint256 wethBalance;
        uint256 usdcBalance;
        int24 currentTick;
        int24 lowerTick;
        int24 upperTick;
        uint128 liquidity;
        uint160 currentSqrtP;
        bool shouldTransferInCallback;
        bool mintLiqudity;
    }

    function setUp() public {
        token0 = new ERC20Mintable("Ether", "ETH", 18);
        token1 = new ERC20Mintable("USDC", "USDC", 18);
    }

    function testMintSuccess() public {
        TestCaseParams memory params = TestCaseParams({
            wethBalance: 1 ether,
            usdcBalance: 5000 ether,
            currentTick: 85176,
            lowerTick: 84222,
            upperTick: 86129,
            liquidity: 1517882343751509868544,
            currentSqrtP: 5602277097478614198912276234240,
            shouldTransferInCallback: true,
            mintLiqudity: true
        });
        (uint256 poolBalance0, uint256 poolBalance1) = setupTestCase(params);

        uint256 expectedAmount0 = 0.998976618347425280 ether;
        uint256 expectedAmount1 = 5000 ether;
        assertEq(
            poolBalance0,
            expectedAmount0,
            "incorrect token0 deposited amount"
        );
        assertEq(
            poolBalance1,
            expectedAmount1,
            "incorrect token1 deposited amount"
        );
    }

    function setupTestCase(
        TestCaseParams memory params
    ) internal returns (uint256 poolBalance0, uint256 poolBalance1) {
        token0.mint(address(this), params.wethBalance);
        token1.mint(address(this), params.usdcBalance);

        pool = new UniswapV3Pool(
            address(token0),
            address(token1),
            params.currentSqrtP,
            params.currentTick
        );

        if (params.mintLiqudity) {
            (poolBalance0, poolBalance1) = pool.mint(
                address(this),
                params.lowerTick,
                params.upperTick,
                params.liquidity
            );
        }

        ShouldTransferInCallback = params.shouldTransferInCallback;
    }

    function uniswapV3MintCallback(uint256 amount0, uint256 amount1) public {
        if (ShouldTransferInCallback) {
            token0.transfer(msg.sender, amount0);
            token1.transfer(msg.sender, amount1);
        }
    }

    // function testSwapBuyEth() public {
    //     TestCaseParams memory params = TestCaseParams({
    //         wethBalance: 1 ether,
    //         usdcBalance: 5000 ether,
    //         currentTick: 85176,
    //         lowerTick: 84222,
    //         upperTick: 86129,
    //         liquidity: 1517882343751509868544,
    //         currentSqrtP: 5602277097478614198912276234240,
    //         shouldTransferInCallback: true,
    //         mintLiqudity: true
    //     });
    //     (uint256 poolBalance0, uint256 poolBalance1) = setupTestCase(params);
    //     token1.mint(address(this), 42 ether);
    //     (int256 amount0Delta, int256 amount1Delta) = pool.swap(address(this));

    //     //uint256 userBalance0Before = token0.balanceOf(address(this));

    //     //最后，我们验证池子的状态是否正确更新：

    //     //函数返回了在本次交易中涉及到的两种 token 数量，我们需要验证一下它们是否正确：
    //     assertEq(amount0Delta, -0.008396714242162444 ether, "invalid ETH out");
    //     assertEq(amount1Delta, 42 ether, "invalid USDC in");
    //     //接下来，我们需要验证 token 的确从调用者（即本测试合约）处转出：
    //     // assertEq(
    //     //     token0.balanceOf(address(this)),
    //     //     uint256(int256(userBalance0Before) - (amount0Delta)),
    //     //     "invalid user ETH balance"
    //     // );
    //     // assertEq(
    //     //     token1.balanceOf(address(this)),
    //     //     0,
    //     //     "invalid user USDC balance"
    //     // );
    //     //并且被发送到了池子合约中：
    // }

    function uniswapV3SwapCallback(int256 amount0, int256 amount1) public {
        if (amount0 > 0) {
            token0.transfer(msg.sender, uint256(amount0));
        }

        if (amount1 > 0) {
            token1.transfer(msg.sender, uint256(amount1));
        }
    }
}
