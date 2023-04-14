// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

import "./solmate/ERC721.sol";

import "./interfaces/IERC20.sol";
import "./interfaces/IUniswapV3Pool.sol";
import "./lib/LiquidityMath.sol";
import "./lib/NFTRenderer.sol";
import "./lib/PoolAddress.sol";
import "./lib/TickMath.sol";

/**
实现了 ERC721 标准并且管理流动性位置。
这个合约将会有 NFT 标准的功能（铸造、燃烧、转移、余额与所有权跟踪等等），
同时也能够向池子添加流动性或者从池子中移除流动性。
这个合约应该是池子中流动性的实际拥有者，
因为我们不希望让用户不铸造 token 就添加流动性，
或者移除了流动性却没有燃烧掉一个 token。
我们希望每个流动性位置都与一个 NFT token 链接，并且始终保持同步。
 */
contract UniswapV3NFTManager is ERC721 {
    error NotAuthorized();
    error NotEnoughLiquidity();
    error PositionNotCleared();
    error SlippageCheckFailed(uint256 amount0, uint256 amount1);
    error WrongToken();

    event AddLiquidity(
        uint256 indexed tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    event RemoveLiquidity(
        uint256 indexed tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    struct TokenPosition {
        address pool;
        int24 lowerTick;
        int24 upperTick;
    }

    uint256 public totalSupply;
    uint256 private nextTokenId;

    address public immutable factory;
    //把 NFT ID 与找到流动性位置所需要的数据联系在一起
    mapping(uint256 => TokenPosition) public positions;
    //权限管理
    modifier isApprovedOrOwner(uint256 tokenId) {
        address owner = ownerOf(tokenId);
        if (
            msg.sender != owner &&
            !isApprovedForAll[owner][msg.sender] &&
            getApproved[tokenId] != msg.sender
        ) revert NotAuthorized();

        _;
    }

    constructor(
        address factoryAddress
    ) ERC721("UniswapV3 NFT Positions", "UNIV3") {
        factory = factoryAddress;
    }

    /**
    在我们实现元数据和 SVG 渲染器之前，这里的 tokenURI 都会返回一个空字符串。
    我们添加这个函数以便于我们在实现合约剩余部分的时候，Solidity 编译器不会因此报错（Solmate ERC721 实现中的 tokenURI 函数被声明为 virtual，
    所以我们必须实现它）。
     */
    function tokenURI(
        uint256 tokenId
    ) public view override returns (string memory) {
        TokenPosition memory tokenPosition = positions[tokenId];
        if (tokenPosition.pool == address(0x00)) revert WrongToken();

        IUniswapV3Pool pool = IUniswapV3Pool(tokenPosition.pool);

        return
            NFTRenderer.render(
                NFTRenderer.RenderParams({
                    pool: tokenPosition.pool,
                    owner: address(this),
                    lowerTick: tokenPosition.lowerTick,
                    upperTick: tokenPosition.upperTick,
                    fee: pool.fee()
                })
            );
    }

    struct MintParams {
        address recipient;
        address tokenA;
        address tokenB;
        uint24 fee;
        int24 lowerTick;
        int24 upperTick;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
    }

    /**
    在池子中添加流动性和铸造一个 NFT
     */
    function mint(MintParams calldata params) public returns (uint256 tokenId) {
        IUniswapV3Pool pool = getPool(params.tokenA, params.tokenB, params.fee);
        /**
    池子地址
    所有者地址
    上下界的 tick
     */
        (uint128 liquidity, uint256 amount0, uint256 amount1) = _addLiquidity(
            /**_addLiquidity 与 UniswapV3Manager 中 mint 函数的部分一致：
            把 tick 转换成 P)，计算流动性数量，然后调用 pool.mint()。 */
            AddLiquidityInternalParams({
                pool: pool,
                lowerTick: params.lowerTick,
                upperTick: params.upperTick,
                amount0Desired: params.amount0Desired,
                amount1Desired: params.amount1Desired,
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min
            })
        );

        tokenId = nextTokenId++;
        _mint(params.recipient, tokenId);
        totalSupply++;

        TokenPosition memory tokenPosition = TokenPosition({
            pool: address(pool),
            lowerTick: params.lowerTick,
            upperTick: params.upperTick
        });

        positions[tokenId] = tokenPosition;

        emit AddLiquidity(tokenId, liquidity, amount0, amount1);
    }

    struct AddLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
    }

    /**
    把流动性添加到已有的位置中。当我们希望我们已经提供过流动性的某个位置拥有更多流动性时我们可以调用。
    在这种情况下，我们并不会铸造一个新的 NFT，而只是增加一个已有位置中流动性的数量。
    在这里，我们仅需要提供 NFT token ID 和 要添加的 token 数量：
     */
    function addLiquidity(
        AddLiquidityParams calldata params
    ) public returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        TokenPosition memory tokenPosition = positions[params.tokenId];
        if (tokenPosition.pool == address(0x00)) revert WrongToken();

        (liquidity, amount0, amount1) = _addLiquidity(
            AddLiquidityInternalParams({
                pool: IUniswapV3Pool(tokenPosition.pool),
                lowerTick: tokenPosition.lowerTick,
                upperTick: tokenPosition.upperTick,
                amount0Desired: params.amount0Desired,
                amount1Desired: params.amount1Desired,
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min
            })
        );

        emit AddLiquidity(params.tokenId, liquidity, amount0, amount1);
    }

    struct RemoveLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
    }

    // TODO: add slippage check
    function removeLiquidity(
        RemoveLiquidityParams memory params
    )
        public
        isApprovedOrOwner(params.tokenId)
        returns (uint256 amount0, uint256 amount1)
    {
        TokenPosition memory tokenPosition = positions[params.tokenId];
        if (tokenPosition.pool == address(0x00)) revert WrongToken();

        IUniswapV3Pool pool = IUniswapV3Pool(tokenPosition.pool);

        (uint128 availableLiquidity, , , , ) = pool.positions(
            poolPositionKey(tokenPosition)
        );
        if (params.liquidity > availableLiquidity) revert NotEnoughLiquidity();

        (amount0, amount1) = pool.burn(
            tokenPosition.lowerTick,
            tokenPosition.upperTick,
            params.liquidity
        );

        emit RemoveLiquidity(
            params.tokenId,
            params.liquidity,
            amount0,
            amount1
        );
    }

    struct CollectParams {
        uint256 tokenId;
        uint128 amount0;
        uint128 amount1;
    }

    function collect(
        CollectParams memory params
    )
        public
        isApprovedOrOwner(params.tokenId)
        returns (uint128 amount0, uint128 amount1)
    {
        TokenPosition memory tokenPosition = positions[params.tokenId];
        if (tokenPosition.pool == address(0x00)) revert WrongToken();

        IUniswapV3Pool pool = IUniswapV3Pool(tokenPosition.pool);

        (amount0, amount1) = pool.collect(
            msg.sender,
            tokenPosition.lowerTick,
            tokenPosition.upperTick,
            params.amount0,
            params.amount1
        );
    }

    //燃烧NFT
    /**
    为了燃烧，对应的位置必须是空的并且 token 已经被收集
     */
    /**
    调用 removeLiquidity 来移除整个区间流动性；
    调用 collect 来收集移除流动性获得的 token；
    调用 burn 来燃烧这个 NFT token。    
     */
    function burn(uint256 tokenId) public isApprovedOrOwner(tokenId) {
        TokenPosition memory tokenPosition = positions[tokenId];
        if (tokenPosition.pool == address(0x00)) revert WrongToken();

        IUniswapV3Pool pool = IUniswapV3Pool(tokenPosition.pool);
        (uint128 liquidity, , , uint128 tokensOwed0, uint128 tokensOwed1) = pool
            .positions(poolPositionKey(tokenPosition));

        if (liquidity > 0 || tokensOwed0 > 0 || tokensOwed1 > 0)
            revert PositionNotCleared();

        delete positions[tokenId];
        _burn(tokenId);
        totalSupply--;
    }

    ////////////////////////////////////////////////////////////////////////////
    //
    // CALLBACKS
    //
    ////////////////////////////////////////////////////////////////////////////
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

    ////////////////////////////////////////////////////////////////////////////
    //
    // INTERNAL
    //
    ////////////////////////////////////////////////////////////////////////////
    struct AddLiquidityInternalParams {
        IUniswapV3Pool pool;
        int24 lowerTick;
        int24 upperTick;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
    }

    function _addLiquidity(
        AddLiquidityInternalParams memory params
    ) internal returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        (uint160 sqrtPriceX96, , , , ) = params.pool.slot0();

        liquidity = LiquidityMath.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(params.lowerTick),
            TickMath.getSqrtRatioAtTick(params.upperTick),
            params.amount0Desired,
            params.amount1Desired
        );

        (amount0, amount1) = params.pool.mint(
            address(this),
            params.lowerTick,
            params.upperTick,
            liquidity,
            abi.encode(
                IUniswapV3Pool.CallbackData({
                    token0: params.pool.token0(),
                    token1: params.pool.token1(),
                    payer: msg.sender
                })
            )
        );

        if (amount0 < params.amount0Min || amount1 < params.amount1Min)
            revert SlippageCheckFailed(amount0, amount1);
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

    /*
        Returns position ID within a pool
    */
    function poolPositionKey(
        TokenPosition memory position
    ) internal view returns (bytes32 key) {
        key = keccak256(
            abi.encodePacked(
                address(this),
                position.lowerTick,
                position.upperTick
            )
        );
    }

    /*
        Returns position ID within the NFT manager
    */
    function positionKey(
        TokenPosition memory position
    ) internal pure returns (bytes32 key) {
        key = keccak256(
            abi.encodePacked(
                address(position.pool),
                position.lowerTick,
                position.upperTick
            )
        );
    }
}
