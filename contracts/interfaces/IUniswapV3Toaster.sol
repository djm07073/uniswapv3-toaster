// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity >=0.7.6;
pragma abicoder v2;
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "./IWETH9.sol";

interface IUniswapV3Toaster {
    struct RebalanceAddParams {
        IUniswapV3Pool pool;
        int24 tickUpper;
        int24 tickLower;
        uint amount0;
        uint amount1;
        address recipient;
        uint8 height;
    }
    struct DecomposeAddParams {
        address pool;
        int24 tickUpper;
        int24 tickLower;
        uint amountC;
        address recipient;
        bytes path; // path[0] = tokenC -> token0 or token1 path
        uint8 height;
    }
    struct RebalanceIncreaseParams {
        uint tokenId;
        uint112 amount0; //
        uint112 amount1;
        uint8 height;
    }

    struct DecomposeIncreaseParams {
        uint tokenId;
        address tokenC;
        uint amountC;
        bytes path; // tokenC -> tokenA or tokenB path
        uint8 height;
    }

    struct RebalanceIncreaseInternalParams {
        uint tokenId;
        uint112 amount0; //-> amount of tokenA
        uint112 amount1; //-> amount of tokenB
        uint8 height;
        address caller;
    }
    struct RebalanceAddInternalParams {
        IUniswapV3Pool pool;
        IQuoterV2 quoter;
        int24 tickUpper;
        int24 tickLower;
        address recipient;
        address caller;
        uint8 height;
    }
    struct RemoveLiquidityParams {
        uint tokenId;
        uint128 liquidityToRemove; // should be calculated by frontend
        bytes path1; //token0 -> dstToken
        bytes path2; // token1 -> dstToken
    }
    struct SwapCallbackData {
        bytes path;
        address payer;
    }

    /**
     * @dev add liquidity to new pool with Rebalancing
     * @notice User should approve tokenA and tokenB to UniswapV3Pool
     * @param params RebalanceAddParams
     * 1. Check pool and path
     * 2. Rebalancing and add liquidity -> _rebalanceAndAddLiquidity
     * 2-1. Calculate Rebalancing Amount -> using RebalanceDepositBS Library
     * 2-2. Swap X to Y or Y to X -> using swap function of SwapRouter code
     * 2-3. add Liquidity to pool -> using mint function of positionManager code
     * 3. Transfer tokens back to user if there is any left
     */
    function rebalanceAndAddLiquidity(
        RebalanceAddParams memory params
    )
        external
        returns (
            uint tokenId,
            uint successLiquidity,
            uint successA,
            uint successB
        );

    // partition function is not needed, because we can use rebalance to do the same thing
    function decomposeAndAddLiquidity(
        DecomposeAddParams memory params
    )
        external
        returns (
            uint tokenId,
            uint successLiquidity,
            uint successA,
            uint successB
        );

    /*** add liquidity to existing pool ***/
    function rebalanceAndIncreaseLiquidity(
        RebalanceIncreaseParams memory params
    ) external returns (uint successLiquidity);

    // function partitionAndIncreaseLiquidity is not needed, because we can use rebalance to do the same thing
    function decomposeAndIncreaseLiquidity(
        DecomposeIncreaseParams memory params
    ) external returns (uint successLiquidity);

    /*** collect fee ***/
    // function collectFee(
    //     uint tokenId,
    //     address to,
    //     address[] memory path1,
    //     address[] memory path2
    // ) external;

    /*** remove liquidity ***/
    function removeLiquidity(RemoveLiquidityParams memory params) external;

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata _data
    ) external;
}
