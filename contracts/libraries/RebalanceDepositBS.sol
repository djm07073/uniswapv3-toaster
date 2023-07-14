pragma solidity >=0.6.0;
pragma abicoder v2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-core/contracts/libraries/SqrtPriceMath.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import "./Math.sol";

library RebalanceDepositBS {
    struct SqrtPriceX96Range {
        uint112 amountX;
        uint112 amountY;
        uint24 fee;
        uint160 upper;
        uint160 lower;
        uint160 price; // sqrtPriceX96
    }

    /**
     * @param pool pool address
     * @param tickUpper tickUpper
     * @param tickLower tickLower
     * @param amountX amount of token X
     * @param amountY amount of token Y
     * @return baseAmount amount of token X or Y to swap
     * @return isSwapX true if swap token X, false if swap token Y
     */
    function rebalanceDeposit(
        IUniswapV3Pool pool,
        IQuoterV2 quoter,
        int24 tickUpper,
        int24 tickLower,
        uint112 amountX,
        uint112 amountY,
        uint8 height
    ) internal returns (uint256 baseAmount, bool isSwapX) {
        require(address(pool) != address(0), "pool does not exist");
        require(tickUpper > tickLower, "UL");

        SqrtPriceX96Range memory range;

        (, int24 tickCurrent, , , , , ) = IUniswapV3Pool(pool).slot0();
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tickCurrent);

        {
            require(tickUpper > tickCurrent, "U");
            require(tickCurrent > tickLower, "L");
            uint160 sqrtPriceX96Upper = TickMath.getSqrtRatioAtTick(tickUpper);
            uint160 sqrtPriceX96Lower = TickMath.getSqrtRatioAtTick(tickLower);

            range = SqrtPriceX96Range(
                amountX,
                amountY,
                pool.fee(),
                sqrtPriceX96Upper,
                sqrtPriceX96Lower,
                sqrtPriceX96
            );
            isSwapX =
                LiquidityAmounts.getLiquidityForAmount0(
                    range.price,
                    range.upper,
                    range.amountX
                ) >
                LiquidityAmounts.getLiquidityForAmount1(
                    range.lower,
                    range.price,
                    range.amountY
                );
        }
        baseAmount = _binarySearch(
            quoter,
            pool.token0(),
            pool.token1(),
            range,
            isSwapX,
            height
        );
    }

    function rebalanceIncrease(
        INonfungiblePositionManager positionManager,
        IQuoterV2 quoter,
        IUniswapV3Factory factory,
        uint tokenId,
        uint112 amountX,
        uint112 amountY,
        uint8 height
    ) internal returns (uint256 baseAmount, bool isSwapX, address pool) {
        SqrtPriceX96Range memory range;
        {
            int24 tickLower;
            int24 tickUpper;
            address tokenA;
            address tokenB;
            uint24 fee;
            (
                ,
                ,
                tokenA,
                tokenB,
                fee,
                tickLower,
                tickUpper,
                ,
                ,
                ,
                ,

            ) = positionManager.positions(tokenId);

            pool = factory.getPool(tokenA, tokenB, fee);
            require(pool != address(0), "pool does not exist");
            (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(pool).slot0();

            int24 tickCurrent;
            (sqrtPriceX96, tickCurrent, , , , , ) = IUniswapV3Pool(pool)
                .slot0();

            range = SqrtPriceX96Range(
                amountX,
                amountY,
                IUniswapV3Pool(pool).fee(),
                TickMath.getSqrtRatioAtTick(tickUpper),
                TickMath.getSqrtRatioAtTick(tickLower),
                sqrtPriceX96
            );
            require(range.upper > range.lower, "UL");
            require(range.upper > sqrtPriceX96, "U");
            require(sqrtPriceX96 > range.lower, "L");
        }

        require(address(pool) != address(0), "pool does not exist");

        isSwapX =
            FullMath.mulDiv(
                range.amountX,
                FullMath.mulDiv(range.price, range.upper, FixedPoint96.Q96),
                range.upper - range.price
            ) >
            FullMath.mulDiv(
                range.amountY,
                FixedPoint96.Q96,
                range.price - range.lower
            );

        baseAmount = _binarySearch(
            quoter,
            IUniswapV3Pool(pool).token0(),
            IUniswapV3Pool(pool).token1(),
            range,
            isSwapX,
            height
        );
    }

    function _binarySearch(
        IQuoterV2 quoter,
        address tokenX,
        address tokenY,
        SqrtPriceX96Range memory range,
        bool isSwapX,
        uint8 height
    ) internal returns (uint amountDelta) {
        uint160 sqrtPriceX96Next;
        uint amountEnd;
        uint amountStart = 0;

        if (isSwapX) {
            // Swap X to Y
            amountEnd = range.amountX;
            uint amountXMid;
            uint amountYDelta;
            for (uint8 _height = 0; _height < height; _height++) {
                // Set amountXMid(amountXDelta)
                // amountXMid = FullMath.mulDiv(
                //     (amountStart + amountEnd) / 2,
                //     1e6,
                //     1e6 - range.fee
                // );
                amountXMid = (amountStart + amountEnd) / 2;
                // get sqrtPriceX96Next and amountYDelta
                // tick이 sqrtPriceX96Next보다 더 큰 경우 다시 계산
                (
                    amountYDelta,
                    sqrtPriceX96Next
                ) = _getNextSqrtPriceX96AndAmountOut(
                    quoter,
                    amountXMid,
                    tokenX,
                    tokenY,
                    range.fee
                );

                if (
                    LiquidityAmounts.getLiquidityForAmount0(
                        sqrtPriceX96Next,
                        range.upper,
                        range.amountX - amountXMid
                    ) >
                    LiquidityAmounts.getLiquidityForAmount1(
                        range.lower,
                        sqrtPriceX96Next,
                        range.amountY + amountYDelta
                    )
                ) {
                    //swapX more ,sqrtPriceX96Next will be more high
                    amountStart = amountXMid;
                } else {
                    // swapX less,sqrtPriceX96Next will be more low
                    amountEnd = amountXMid;
                }
            }
            amountDelta = amountXMid;
        } else {
            // Swap Y to X
            uint amountYMid;
            uint amountXDelta;
            amountEnd = range.amountY;
            for (uint8 _height = 0; _height < height; _height++) {
                // Set amountXMid(amountXDelta)
                // amountYMidAfterFee = (amountStart + amountEnd) / 2;
                amountYMid = (amountStart + amountEnd) / 2;
                // get sqrtPriceX96Next
                (
                    amountXDelta,
                    sqrtPriceX96Next
                ) = _getNextSqrtPriceX96AndAmountOut(
                    quoter,
                    amountYMid,
                    tokenY,
                    tokenX,
                    range.fee
                );

                if (
                    LiquidityAmounts.getLiquidityForAmount1(
                        range.lower,
                        sqrtPriceX96Next,
                        range.amountY - amountYMid
                    ) >
                    LiquidityAmounts.getLiquidityForAmount0(
                        sqrtPriceX96Next,
                        range.upper,
                        range.amountX + amountXDelta
                    )
                ) {
                    //swapY more ,PriceX96Next will be more low
                    amountStart = amountYMid;
                } else {
                    // swapY less,PriceX96Next will be more high
                    amountEnd = amountYMid;
                }
            }
            amountDelta = amountYMid;
        }
    }

    function _getNextSqrtPriceX96AndAmountOut(
        IQuoterV2 quoter,
        uint256 amountIn,
        address tokenIn,
        address tokenOut,
        uint24 fee
    ) internal returns (uint amountOut, uint160 sqrtPriceX96Next) {
        // use OuoterV2 code
        IQuoterV2.QuoteExactInputSingleParams memory params = IQuoterV2
            .QuoteExactInputSingleParams(tokenIn, tokenOut, amountIn, fee, 0);

        (amountOut, sqrtPriceX96Next, , ) = quoter.quoteExactInputSingle(
            params
        );
    }
}
