// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "./interfaces/IUniswapV3PoolDeployer.sol";
import "./UniswapV3Pool.sol";

contract UniswapV3Factory is IUniswapV3PoolDeployer {
    error PoolAlreadyExists();
    error ZeroAddressNotAllowed();
    error TokensMustBeDifferent();
    error UnsupportedTickSpacing();

    event PoolCreated(
        address indexed token0,
        address indexed token1,
        uint24 indexed tickSpacing,
        //这三个参数可以定位池子 和salt产生池子地址
        address pool
    );

    PoolParameters public parameters;

    mapping(uint24 => uint24) public fees;
    //mapping(uint24 => bool) public tickSpacings;
    mapping(address => mapping(address => mapping(uint24 => address)))
        public pools;

    /*费率和 tick 间隔绑定：费率越高，tick 间隔越大。
    这是因为稳定性越高的池子（稳定币池）的费率应该更低。 */
    constructor() {
        //tickSpacings[10] = true;
        //tickSpacings[60] = true;
        /**费率的单位是基点的百分之一，也
        即一个费率单位是 0.0001%，500 是 0.05%，3000 是 0.3%。 */
        fees[500] = 10;
        fees[3000] = 60;
    }

    function createPool(
        address tokenX,
        address tokenY,
        uint24 fee
    ) public returns (address pool) {
        if (tokenX == tokenY) revert TokensMustBeDifferent();
        //if (!tickSpacings[tickSpacing]) revert UnsupportedTickSpacing();
        if (fees[fee] == 0) revert UnsupportedFee();
        //定义方向 X<Y
        (tokenX, tokenY) = tokenX < tokenY
            ? (tokenX, tokenY)
            : (tokenY, tokenX);
        if (tokenX == address(0)) revert ZeroAddressNotAllowed();
        if (pools[tokenX][tokenY][fee] != address(0))
            revert PoolAlreadyExists();
        parameters = PoolParameters({
            factory: address(this),
            token0: tokenX,
            token1: tokenY,
            tickSpacing: fees[fee],
            fee: fee
        });
        //传入hash值进行初始化构造函数
        pool = address(
            new UniswapV3Pool{
                salt: keccak256(abi.encodePacked(tokenX, tokenY, fee))
            }()
        );
        delete parameters;
        pools[tokenX][tokenY][fee] = pool;

        pools[tokenY][tokenX][fee] = pool;

        emit PoolCreated(tokenX, tokenY, fee, pool);
    }
}
