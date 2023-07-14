// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;
import "../libraries/RebalanceDepositBS.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

contract RebalanceDepositTestBS {
    function rebalanceDepositTestBS(
        IUniswapV3Pool pool,
        IQuoterV2 quoter,
        int24 tickUpper,
        int24 tickLower,
        uint112 amountX,
        uint112 amountY,
        uint8 height
    ) public returns (uint baseAmount, bool isSwapX) {
        (baseAmount, isSwapX) = RebalanceDepositBS.rebalanceDeposit(
            pool,
            quoter,
            tickUpper,
            tickLower,
            amountX,
            amountY,
            height
        );
    }

    function rebalanceIncreaseTestBS(
        INonfungiblePositionManager positionManager,
        IQuoterV2 quoter,
        IUniswapV3Factory factory,
        uint tokenId,
        uint112 amountX,
        uint112 amountY,
        uint8 height
    ) public returns (uint256 baseAmount, bool isSwapX, address pool) {
        return
            RebalanceDepositBS.rebalanceIncrease(
                positionManager,
                quoter,
                factory,
                tokenId,
                amountX,
                amountY,
                height
            );
    }
}
