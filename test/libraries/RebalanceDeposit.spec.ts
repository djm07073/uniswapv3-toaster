import setting from "../../scripts/utils/setting";
import ADDRESS from "../../config/address-mainnet-fork.json";
import { expect } from "chai";
import {
  IERC20,
  INonfungiblePositionManager,
  IQuoterV2,
  ISwapRouter,
  IUniswapV3Pool,
  IWETH9,
  RebalanceDepositTestBS,
  RebalanceDepositTestBS__factory,
} from "../../typechain-types";
import { ethers } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

let test_case: {
  randomAmount: number;
  randomIncreseAmount: number;
  randomUpperTick: bigint;
  randomLowerTick: bigint;
}[] = [];
for (let i = 1; i <= 3; i++) {
  for (let j = 0; j < 2; j++) {
    let randomAmount: number = Math.random() * 1000;
    let randomUpperTick: bigint = BigInt(Math.floor(Math.random() * 12000));
    let randomLowerTick: bigint = BigInt(Math.floor(Math.random() * 12000));
    let randomIncreseAmount: number = Math.floor(Math.random() * 100);

    test_case.push({
      randomAmount: randomAmount,
      randomIncreseAmount: randomIncreseAmount,
      randomUpperTick: randomUpperTick,
      randomLowerTick: randomLowerTick,
    });
  }
}
let swapRouter: ISwapRouter;
let nonfungiblePositionManager: INonfungiblePositionManager;
let UniswapV3Pool: IUniswapV3Pool;
let WETH: IWETH9;
let tick: bigint;
let tickLower: bigint;
let tickUpper: bigint;
let token0: IERC20;
let token1: IERC20;
let signer: HardhatEthersSigner;
let quoter: IQuoterV2;
let rebalanceDeposit: RebalanceDepositTestBS;
let balanceOfToken0: bigint;
let balanceOfToken1: bigint;
let tokenId: bigint;
let index: bigint;
let c: number = 1;
describe("Test RebalanceDeposit Library in 6 Random case on WETH/MATIC(fee: 0.3%) POOL", () => {
  before("Deploy Fixture", async () => {
    const rebalanceDeposit_f: RebalanceDepositTestBS__factory =
      await ethers.getContractFactory("RebalanceDepositTestBS");
    rebalanceDeposit = await rebalanceDeposit_f
      .deploy()
      .then((t) => t.waitForDeployment());
    const res = await setting(
      ADDRESS.POOL_MATIC_WETH,
      ADDRESS.WETH,
      ADDRESS.QUOTER,
      ADDRESS.SWAP_ROUTER,
      ADDRESS.NFTPOSITIONMANAGER
    );
    signer = res.signer;
    swapRouter = res.SwapRouter;
    nonfungiblePositionManager = res.NonfungiblePositionManager;
    UniswapV3Pool = res.UniswapV3Pool;
    WETH = res.WETH;
    token0 = res.token0;
    token1 = res.token1;
    quoter = res.Quoter;
  });
  for (const {
    randomAmount,
    randomIncreseAmount,
    randomUpperTick,
    randomLowerTick,
  } of test_case) {
    it(`Test ${c} case Make MATIC : MATIC of value equal to ${randomAmount} WETH value WETH : ${
      1000 - randomAmount
    }`, async () => {
      await WETH.connect(signer).deposit({
        value: ethers.parseEther("1000"),
      });
      await token0
        .approve(await swapRouter.getAddress(), ethers.MaxUint256)
        .then((t) => t.wait());
      await token1
        .approve(await swapRouter.getAddress(), ethers.MaxUint256)
        .then((t) => t.wait());
      await token0
        .approve(
          await nonfungiblePositionManager.getAddress(),
          ethers.MaxUint256
        )
        .then((t) => t.wait());
      await token1
        .approve(
          await nonfungiblePositionManager.getAddress(),
          ethers.MaxUint256
        )
        .then((t) => t.wait());
      await swapRouter.exactInputSingle({
        tokenIn: ADDRESS.WETH,
        tokenOut: ADDRESS.MATIC,
        fee: 3000,
        recipient: signer.address,
        deadline: ethers.MaxUint256,
        amountIn: ethers.parseEther(randomAmount.toString()),
        amountOutMinimum: 0,
        sqrtPriceLimitX96: 0,
      });

      tick = await UniswapV3Pool.slot0().then((t) => t.tick);
      tickLower = tick - randomLowerTick;
      tickUpper = tick + randomUpperTick;
      tickLower = (tickLower / 60n) * 60n; // round down to multiple of 60
      tickUpper = (tickUpper / 60n) * 60n;
    });

    it(`Calculate rebalancing: Swap & Add Liquidity on range of (current tick +${randomUpperTick} ~ current tick - ${randomLowerTick})`, async () => {
      balanceOfToken0 = await token0.balanceOf(signer.address);
      balanceOfToken1 = await token1.balanceOf(signer.address);

      const { baseAmount, isSwapX } =
        await rebalanceDeposit.rebalanceDepositTestBS.staticCall(
          await UniswapV3Pool.getAddress(),
          await quoter.getAddress(),
          tickUpper,
          tickLower,
          balanceOfToken0,
          balanceOfToken1,
          32
        );

      if (isSwapX) {
        // Swap WETH
        await swapRouter.exactInputSingle({
          tokenIn: await token0.getAddress(),
          tokenOut: await token1.getAddress(),
          fee: 3000,
          recipient: signer.address,
          deadline: ethers.MaxUint256,
          amountIn: baseAmount,
          amountOutMinimum: 0,
          sqrtPriceLimitX96: 0,
        });
      } else {
        // Swap MATIC
        await swapRouter.exactInputSingle({
          tokenIn: await token1.getAddress(),
          tokenOut: await token0.getAddress(),
          fee: 3000,
          recipient: signer.address,
          deadline: ethers.MaxUint256,
          amountIn: baseAmount,
          amountOutMinimum: 0,
          sqrtPriceLimitX96: 0,
        });
      }

      await nonfungiblePositionManager.mint({
        token0: await token0.getAddress(),
        token1: await token1.getAddress(),
        fee: 3000,
        tickLower: tickLower,
        tickUpper: tickUpper,
        amount0Desired: await token0.balanceOf(signer.address),
        amount1Desired: await token1.balanceOf(signer.address),
        amount0Min: 0,
        amount1Min: 0,
        recipient: signer.address,
        deadline: ethers.MaxUint256,
      });
      expect(
        await token0.balanceOf(signer.address),
        "The MATIC remaining after add liquidity is less than 0.002"
      ).to.be.lt(ethers.parseEther("0.002"));
      expect(
        await token1.balanceOf(signer.address),
        "The WETH remaining after add liquidity is less than 0.00001"
      ).to.be.lt(ethers.parseEther("0.00001"));
      index = await nonfungiblePositionManager.balanceOf(signer.address);
      tokenId = await nonfungiblePositionManager.tokenOfOwnerByIndex(
        signer.address,
        (await nonfungiblePositionManager.balanceOf(signer.address)) - 1n
      );
    });

    it(`Recharge WETH ${randomIncreseAmount} & MATIC ${
      100 - randomIncreseAmount
    } RebalanceIncrease in Existing `, async () => {
      await WETH.deposit({ value: ethers.parseEther("100") });
      //
      await swapRouter.exactInputSingle({
        tokenIn: ADDRESS.WETH,
        tokenOut: await token0.getAddress(),
        fee: 3000,
        recipient: signer.address,
        deadline: ethers.MaxUint256,
        amountIn: ethers.parseEther((100 - randomIncreseAmount).toString()),
        amountOutMinimum: 0,
        sqrtPriceLimitX96: 0,
      });

      balanceOfToken0 = await token0.balanceOf(signer.address);
      balanceOfToken1 = await token1.balanceOf(signer.address);

      const { baseAmount, isSwapX, fee, tokenA, tokenB } =
        await rebalanceDeposit.rebalanceIncreaseTestBS.staticCall(
          ADDRESS.NFTPOSITIONMANAGER,
          ADDRESS.QUOTER,
          ADDRESS.UNISWAP_FACTORY,
          tokenId,
          balanceOfToken0,
          balanceOfToken1,
          32
        );
      if (isSwapX) {
        await swapRouter.exactInputSingle({
          tokenIn: await token0.getAddress(),
          tokenOut: await token1.getAddress(),
          fee: fee,
          recipient: signer.address,
          deadline: ethers.MaxUint256,
          amountIn: baseAmount,
          amountOutMinimum: 0,
          sqrtPriceLimitX96: 0,
        });
      } else {
        await swapRouter.exactInputSingle({
          tokenIn: await token1.getAddress(),
          tokenOut: await token0.getAddress(),
          fee: fee,
          recipient: signer.address,
          deadline: ethers.MaxUint256,
          amountIn: baseAmount,
          amountOutMinimum: 0,
          sqrtPriceLimitX96: 0,
        });
      }

      await nonfungiblePositionManager.increaseLiquidity({
        tokenId: tokenId,
        amount0Desired: await token0.balanceOf(signer.address),
        amount1Desired: await token1.balanceOf(signer.address),
        amount0Min: 0,
        amount1Min: 0,
        deadline: ethers.MaxUint256,
      });
      balanceOfToken0 = await token0.balanceOf(signer.address);
      balanceOfToken1 = await token1.balanceOf(signer.address);

      expect(
        await token0.balanceOf(signer.address),
        "The MATIC remaining after increasing liquidity is less than 0.001"
      ).to.be.lt(ethers.parseEther("0.001"));
      expect(
        await token1.balanceOf(signer.address),
        "The WETH remaining after increasing liquidity is less than 0.0001"
      ).to.be.lt(ethers.parseEther("0.0001"));
    });
    c++;
  }
});
