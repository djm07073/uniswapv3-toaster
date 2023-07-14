// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity >=0.7.6;
pragma abicoder v2;

import "@uniswap/v3-core/contracts/interfaces/IERC20Minimal.sol";
import "@uniswap/lib/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-periphery/contracts/libraries/Path.sol";
import "@uniswap/v3-periphery/contracts/libraries/CallbackValidation.sol";
import "./libraries/RebalanceDepositBS.sol";
import "./interfaces/IUniswapV3Toaster.sol";
import "./interfaces/IWETH9.sol";

abstract contract UniswapV3Toaster is IUniswapV3Toaster {
    INonfungiblePositionManager public immutable positionManager;
    IUniswapV3Factory public immutable factory;
    IQuoterV2 public immutable quoter;
    IWETH9 public immutable weth;
    /// @dev Used as the placeholder value for amountInCached, because the computed amount in for an exact output swap
    /// can never actually be this value
    uint256 private constant DEFAULT_AMOUNT_IN_CACHED = type(uint256).max;
    uint256 private amountInCached = DEFAULT_AMOUNT_IN_CACHED;
    using Path for bytes;
    using SafeCast for uint256;

    constructor(
        INonfungiblePositionManager _positionManager,
        IUniswapV3Factory _factory,
        IQuoterV2 _quoter,
        IWETH9 _weth9
    ) {
        positionManager = _positionManager;
        factory = _factory;
        quoter = _quoter;
        weth = _weth9;
    }

    /*******************************************************************************
     * How to add Liquidity? if I have 100 USD of value in Token
     * if depositUSDRatio, A/B == 40/60 is the current ratio decided by upper tick and lower tick
     * Rebalance: A(63) + B(37) -> A(40) + B(60)
     * Partition: A(100) + B(0) -> A(40) + B(60)
     * Decompose: C(100) -> A(40) + B(60)
     ******************************************************************************/

    function rebalanceAndAddLiquidity(
        RebalanceAddParams memory params
    )
        external
        override
        returns (
            uint tokenId,
            uint successLiquidity,
            uint successA,
            uint successB
        )
    {
        //1.
        require(address(params.pool) != address(0), "pool must exist");
        require(params.tickUpper > params.tickLower, "UL");
        //2.
        (
            tokenId,
            successLiquidity,
            successA,
            successB
        ) = _rebalanceAndAddLiquidity(
            RebalanceAddInternalParams(
                IUniswapV3Pool(params.pool),
                IQuoterV2(address(quoter)),
                params.tickUpper,
                params.tickLower,
                params.recipient, //if mint by myself, to = msg.sender
                msg.sender,
                params.height
            )
        );
    }

    // partition function is not needed, because we can use rebalance to do the same thing
    function decomposeAndAddLiquidity(
        DecomposeAddParams memory params
    )
        external
        override
        returns (
            uint tokenId,
            uint successLiquidity,
            uint successA,
            uint successB
        )
    {
        // 1. check pool and path
        require(params.pool != address(0), "pool must exist");

        // 2. Swap amountC of tokenC to token0 or token1 by given path
        {
            uint amountOut;
            address payer = msg.sender;
            while (true) {
                bool hasMultiplePools = params.path.hasMultiplePools();

                // the outputs of prior swaps become the inputs to subsequent ones
                params.amountC = exactInputInternal(
                    params.amountC,
                    address(this), // for intermediate swaps, this contract custodies
                    0,
                    SwapCallbackData({
                        path: params.path.getFirstPool(), // only the first pool in the path is necessary
                        payer: payer
                    })
                );

                // decide whether to continue or terminate
                if (hasMultiplePools) {
                    payer = address(this); // at this point, the caller has paid
                    params.path = params.path.skipToken();
                } else {
                    amountOut = params.amountC;
                    break;
                }
            }
        }
        // 3. Rebalance amountOut and add liquidity and mint to "recipient"
        (
            tokenId,
            successLiquidity,
            successA,
            successB
        ) = _rebalanceAndAddLiquidity(
            RebalanceAddInternalParams(
                IUniswapV3Pool(params.pool),
                IQuoterV2(address(quoter)),
                params.tickUpper,
                params.tickLower,
                params.recipient,
                msg.sender,
                params.height
            )
        );
    }

    /* 1. Check pool and path
     * 2. Rebalancing and add liquidity -> _rebalanceAndAddLiquidity
     * 2-1. Calculate Rebalancing Amount -> using RebalanceDepositBS Library
     * 2-2. Swap X to Y or Y to X -> using swap function of SwapRouter code
     * 2-3. add Liquidity to pool -> using increase Liquidity function of positionManager code
     * 3. Transfer tokens back to user if there is any left
     * /
    /*** increase liquidity to existing pool ***/
    function rebalanceAndIncreaseLiquidity(
        RebalanceIncreaseParams memory params
    ) external override returns (uint successLiquidity) {
        //1.
        (successLiquidity) = _rebalanceAndIncreaseLiquidity(
            RebalanceIncreaseInternalParams(
                params.tokenId,
                params.amount0,
                params.amount1,
                params.height,
                msg.sender // to be user
            )
        );
    }

    // function partitionAndIncreaseLiquidity is not needed, because we can use rebalance to do the same thing
    function decomposeAndIncreaseLiquidity(
        DecomposeIncreaseParams memory params
    ) external override returns (uint successLiquidity) {
        (, , address token0, address token1, , , , , , , , ) = positionManager
            .positions(params.tokenId);
        // 1. check pool and path
        {
            address[] memory path = abi.decode(params.path, (address[]));
            require(
                path[path.length - 1] == token0 ||
                    path[path.length - 1] == token1,
                "path must end with token0 or token1"
            );
        }
        // 2. Swap amountC of tokenC to token0 or token1 by given path
        {
            uint amountOut;
            address payer = msg.sender;
            while (true) {
                bool hasMultiplePools = params.path.hasMultiplePools();

                // the outputs of prior swaps become the inputs to subsequent ones
                params.amountC = exactInputInternal(
                    params.amountC,
                    address(this), // for intermediate swaps, this contract custodies
                    0,
                    SwapCallbackData({
                        path: params.path.getFirstPool(), // only the first pool in the path is necessary
                        payer: payer
                    })
                );

                // decide whether to continue or terminate
                if (hasMultiplePools) {
                    payer = address(this); // at this point, the caller has paid
                    params.path = params.path.skipToken();
                } else {
                    amountOut = params.amountC;
                    break;
                }
            }
        }
        //3.
        (successLiquidity) = _rebalanceAndIncreaseLiquidity(
            RebalanceIncreaseInternalParams(
                params.tokenId,
                uint112(IERC20Minimal(token0).balanceOf(address(this))),
                uint112(IERC20Minimal(token1).balanceOf(address(this))),
                params.height,
                msg.sender // to be user
            )
        );
    }

    /*** collect fee ***/
    // 만들까? 말까?

    /*** remove liquidity ***/
    function removeLiquidity(
        RemoveLiquidityParams memory params
    ) external override {
        //1. Confirm Path
        {
            address[] memory path1 = abi.decode(params.path1, (address[]));
            address[] memory path2 = abi.decode(params.path2, (address[]));
            require(
                path1[path1.length - 1] == path2[path2.length - 1],
                "destination token is different"
            );
            (
                ,
                ,
                address tokenA,
                address tokenB,
                ,
                ,
                ,
                uint128 liquidity,
                ,
                ,
                ,

            ) = positionManager.positions(params.tokenId);
            require(
                path1[0] == tokenA && path2[0] == tokenB,
                "path of src token is wrong"
            );
        }
        //2. Transfer NFT to this contract
        positionManager.safeTransferFrom(
            msg.sender,
            address(this),
            params.tokenId
        );
        //3. Decrease liquidity
        (uint amountA, uint amountB) = positionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: params.tokenId,
                liquidity: params.liquidityToRemove,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint).max
            })
        );
        //4. Swap to dstToken and Transfer to user

        //5. Transfer NFT to user if there is any left liquidity
    }

    function _rebalanceAndAddLiquidity(
        RebalanceAddInternalParams memory params
    )
        internal
        returns (
            uint tokenId,
            uint successLiquidity,
            uint successA,
            uint successB
        )
    {
        // 2-1. Calculate Rebalancing Amount and isSwapX -> using RebalanceDepositBS Library
        (uint baseAmount, bool isSwapX) = RebalanceDepositBS.rebalanceDeposit(
            params.pool,
            params.quoter,
            params.tickUpper,
            params.tickLower,
            uint112(
                IERC20Minimal(params.pool.token0()).balanceOf(address(this))
            ),
            uint112(
                IERC20Minimal(params.pool.token1()).balanceOf(address(this))
            ),
            params.height
        );

        // 2-2. Swap X to Y or Y to X in a pool to invest in -> using swap function of SwapRouter code
        exactInputInternal(
            baseAmount,
            address(this),
            0,
            SwapCallbackData({
                path: abi.encodePacked(
                    isSwapX ? (params.pool.token0()) : (params.pool.token1()),
                    params.pool.fee(),
                    isSwapX ? (params.pool.token1()) : (params.pool.token0())
                ),
                payer: params.caller
            })
        );
        // If the swapping for rebalancing makes the tickUpper and tickLower invalid, revert
        {
            (, int24 tick, , , , , ) = params.pool.slot0();
            require(
                params.tickUpper > tick,
                "Swapping for Rebalance make tickUpper < tick"
            );
            require(
                params.tickLower < tick,
                "Swapping for Rebalance make tickLower > tick"
            );
        }
        // 2-3. add Liquidity to pool -> call positionManger.mint()
        (tokenId, successLiquidity, successA, successB) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: params.pool.token0(),
                token1: params.pool.token1(),
                fee: params.pool.fee(),
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                amount0Desired: IERC20Minimal(params.pool.token0()).balanceOf(
                    address(this)
                ),
                amount1Desired: IERC20Minimal(params.pool.token1()).balanceOf(
                    address(this)
                ),
                amount0Min: 0,
                amount1Min: 0,
                recipient: params.recipient,
                deadline: type(uint).max
            })
        );

        //3.
        _transferRemainingTokens(
            IERC20Minimal(params.pool.token0()),
            IERC20Minimal(params.pool.token1()),
            params.caller
        );
    }

    /* 2-1. Calculate Rebalancing Amount -> using RebalanceDepositBS Library
     * 2-2. Swap X to Y or Y to X -> using swap function of SwapRouter code
     * 2-3. add Liquidity to pool -> using increase Liquidity function of positionManager code
     */
    function _rebalanceAndIncreaseLiquidity(
        RebalanceIncreaseInternalParams memory params
    ) internal returns (uint) {
        //2-1. Calculate how much token A to swap or how much token B to swap
        (uint baseAmount, bool isSwapX, address _pool) = RebalanceDepositBS
            .rebalanceIncrease(
                positionManager,
                quoter,
                factory,
                params.tokenId,
                params.amount0,
                params.amount1,
                params.height
            );
        //2-2. Swap X to Y or Y to X
        exactInputInternal(
            baseAmount,
            address(this),
            0,
            SwapCallbackData({
                path: abi.encodePacked(
                    isSwapX
                        ? (IUniswapV3Pool(_pool).token0())
                        : (IUniswapV3Pool(_pool).token1()),
                    IUniswapV3Pool(_pool).fee(),
                    isSwapX
                        ? (IUniswapV3Pool(_pool).token1())
                        : (IUniswapV3Pool(_pool).token0())
                ),
                payer: params.caller
            })
        );

        //2-3. Increase liquidity
        (uint successLiquidity, , ) = positionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: params.tokenId,
                amount0Desired: IERC20Minimal(IUniswapV3Pool(_pool).token0())
                    .balanceOf(address(this)),
                amount1Desired: IERC20Minimal(IUniswapV3Pool(_pool).token1())
                    .balanceOf(address(this)),
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint).max
            })
        );

        //3.
        _transferRemainingTokens(
            IERC20Minimal(IUniswapV3Pool(_pool).token0()),
            IERC20Minimal(IUniswapV3Pool(_pool).token1()),
            msg.sender
        );
        return (successLiquidity);
    }

    /// @dev Performs a single exact input swap
    function exactInputInternal(
        uint256 amountIn,
        address recipient,
        uint160 sqrtPriceLimitX96,
        SwapCallbackData memory data
    ) private returns (uint256 amountOut) {
        // allow swapping to the router address with address 0
        if (recipient == address(0)) recipient = address(this);

        (address tokenIn, address tokenOut, uint24 fee) = data
            .path
            .decodeFirstPool();

        bool zeroForOne = tokenIn < tokenOut;

        (int256 amount0, int256 amount1) = getPool(tokenIn, tokenOut, fee).swap(
            recipient,
            zeroForOne,
            amountIn.toInt256(),
            sqrtPriceLimitX96 == 0
                ? (
                    zeroForOne
                        ? TickMath.MIN_SQRT_RATIO + 1
                        : TickMath.MAX_SQRT_RATIO - 1
                )
                : sqrtPriceLimitX96,
            abi.encode(data)
        );

        return uint256(-(zeroForOne ? amount1 : amount0));
    }

    function exactOutputInternal(
        uint256 amountOut,
        address recipient,
        uint160 sqrtPriceLimitX96,
        SwapCallbackData memory data
    ) private returns (uint256 amountIn) {
        // allow swapping to the router address with address 0
        if (recipient == address(0)) recipient = address(this);

        (address tokenOut, address tokenIn, uint24 fee) = data
            .path
            .decodeFirstPool();

        bool zeroForOne = tokenIn < tokenOut;

        (int256 amount0Delta, int256 amount1Delta) = getPool(
            tokenIn,
            tokenOut,
            fee
        ).swap(
                recipient,
                zeroForOne,
                -amountOut.toInt256(),
                sqrtPriceLimitX96 == 0
                    ? (
                        zeroForOne
                            ? TickMath.MIN_SQRT_RATIO + 1
                            : TickMath.MAX_SQRT_RATIO - 1
                    )
                    : sqrtPriceLimitX96,
                abi.encode(data)
            );

        uint256 amountOutReceived;
        (amountIn, amountOutReceived) = zeroForOne
            ? (uint256(amount0Delta), uint256(-amount1Delta))
            : (uint256(amount1Delta), uint256(-amount0Delta));
        // it's technically possible to not receive the full output amount,
        // so if no price limit has been specified, require this possibility away
        if (sqrtPriceLimitX96 == 0) require(amountOutReceived == amountOut);
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata _data
    ) external override {
        require(amount0Delta > 0 || amount1Delta > 0); // swaps entirely within 0-liquidity regions are not supported
        SwapCallbackData memory data = abi.decode(_data, (SwapCallbackData));
        (address tokenIn, address tokenOut, uint24 fee) = data
            .path
            .decodeFirstPool();
        CallbackValidation.verifyCallback(
            address(factory),
            tokenIn,
            tokenOut,
            fee
        );

        (bool isExactInput, uint256 amountToPay) = amount0Delta > 0
            ? (tokenIn < tokenOut, uint256(amount0Delta))
            : (tokenOut < tokenIn, uint256(amount1Delta));
        if (isExactInput) {
            pay(tokenIn, data.payer, msg.sender, amountToPay);
        } else {
            // either initiate the next swap or pay
            if (data.path.hasMultiplePools()) {
                data.path = data.path.skipToken();
                exactOutputInternal(amountToPay, msg.sender, 0, data); // msg.sender
            } else {
                amountInCached = amountToPay;
                tokenIn = tokenOut; // swap in/out because exact output swaps are reversed
                pay(tokenIn, data.payer, msg.sender, amountToPay);
            }
        }
    }

    function pay(
        address token,
        address payer,
        address recipient,
        uint256 value
    ) internal {
        if (token == address(weth) && address(this).balance >= value) {
            // pay with WETH9
            weth.deposit{value: value}(); // wrap only what is needed to pay
            weth.transfer(recipient, value);
        } else if (payer == address(this)) {
            // pay with tokens already in the contract (for the exact input multihop case)
            TransferHelper.safeTransfer(token, recipient, value);
        } else {
            // pull payment
            TransferHelper.safeTransferFrom(token, payer, recipient, value);
        }
    }

    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) private view returns (IUniswapV3Pool) {
        return
            IUniswapV3Pool(
                PoolAddress.computeAddress(
                    address(factory),
                    PoolAddress.getPoolKey(tokenA, tokenB, fee)
                )
            );
    }

    function _transferRemainingTokens(
        IERC20Minimal tokenA,
        IERC20Minimal tokenB,
        address to
    ) internal {
        if (tokenA.balanceOf(address(this)) != 0) {
            TransferHelper.safeTransferFrom(
                address(tokenA),
                address(this),
                to,
                tokenA.balanceOf(address(this))
            );
        }
        if (tokenB.balanceOf(address(this)) != 0) {
            TransferHelper.safeTransferFrom(
                address(tokenB),
                address(this),
                to,
                tokenB.balanceOf(address(this))
            );
        }
    }
    /********** view function for showing result************/
}
