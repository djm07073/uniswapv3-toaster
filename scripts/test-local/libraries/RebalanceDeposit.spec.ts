import { ethers } from "hardhat";
import { RebalanceDepositTestBS__factory } from "../../../typechain-types";
import setting from "../../utils/setting";
import ADDRESS from "../../../config/address-mainnet-fork.json";
async function test(
  _pool: string,
  _weth: string,
  _quoter: string,
  _swapRouter: string,
  _nonfungiblePositionManager: string,
  fee: number
) {
  console.log("Setting up Test Environment");
  let {
    SwapRouter: swapRouter,
    NonfungiblePositionManager: nonfungiblePositionManager,
    UniswapV3Pool: UniswapV3Pool,
    WETH: weth,
    tick: tick,
    token0: token0,
    token1: token1,
  } = await setting(
    _pool,
    _weth,
    _quoter,
    _swapRouter,
    _nonfungiblePositionManager
  );
  const [signer] = await ethers.getSigners();
  console.log("Swap WETH to MATIC");
  await weth.approve(_swapRouter, ethers.MaxUint256).then((tx) => tx.wait());
  await swapRouter
    .exactInputSingle({
      tokenIn: _weth,
      tokenOut: (await token0).getAddress(),
      fee: 3000,
      recipient: signer.address,
      deadline: ethers.MaxUint256,
      amountIn: ethers.parseEther("40"),
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0,
    })
    .then((tx) => tx.wait());

  // [FIXED]
  const currentTick = await UniswapV3Pool.slot0().then((t) => t.tick);
  let tickLower = currentTick - 6000n;
  let tickUpper = currentTick + 6900n;
  (tickLower = (tickLower / 60n) * 60n), // round down to multiple of 60
    (tickUpper = (tickUpper / 60n) * 60n), // round down to multiple of 60
    console.log("Signer");
  console.log("***************Test Rebalance Deposit Test******************");

  const rebalanceDeposit_f: RebalanceDepositTestBS__factory =
    await ethers.getContractFactory("RebalanceDepositTestBS");
  const rebalanceDeposit = await rebalanceDeposit_f
    .deploy()
    .then((t) => t.waitForDeployment());

  console.log(
    "RebalanceDeposit deployed to:",
    await rebalanceDeposit.getAddress()
  );

  tick = await UniswapV3Pool.slot0().then((t) => t.tick);

  console.log(
    "Before swap, balance of token0(MATIC), token1(WETH) :",
    ethers.formatEther(await token0.balanceOf(signer.address)),
    ethers.formatEther(await token1.balanceOf(signer.address))
  );

  const { baseAmount, isSwapX } =
    await rebalanceDeposit.rebalanceDepositTestBS.staticCall(
      _pool,
      _quoter,
      tickUpper,
      tickLower,
      await token0.balanceOf(signer.address),
      await token1.balanceOf(signer.address),
      32
    );

  console.log(
    "Base Amount , isSwapX: ",
    ethers.formatEther(baseAmount),
    isSwapX
  );
  console.log("Approve Swap Router");

  await token0.approve(_swapRouter, ethers.MaxUint256).then((tx) => tx.wait());
  await token1.approve(_swapRouter, ethers.MaxUint256).then((tx) => tx.wait());
  console.log(
    "Before swap, tick, tickUpper, tickLower:",
    tick,
    tickUpper,
    tickLower
  );

  if (isSwapX) {
    console.log("Swap X to Y");

    await swapRouter
      .exactInputSingle({
        tokenIn: token0,
        tokenOut: token1,
        fee: fee,
        recipient: signer.address,
        deadline: 1514739398841430622086649900n,
        amountIn: baseAmount,
        amountOutMinimum: 1,
        sqrtPriceLimitX96: 0,
      })
      .then((tx) => tx.wait());

    tick = await UniswapV3Pool.slot0().then((t) => t.tick);
    console.log(
      "After swap, tick, tickUpper, tickLower:",
      tick,
      tickUpper,
      tickLower
    );

    console.log(
      "After swap, balance of token0(MATIC), token1(WETH) :",
      ethers.formatEther(await token0.balanceOf(signer.address)),
      ethers.formatEther(await token1.balanceOf(signer.address))
    );
  } else {
    console.log("Swap Y to X");

    await swapRouter
      .exactInputSingle({
        tokenIn: token1,
        tokenOut: token0,
        fee: fee,
        recipient: signer.address,
        deadline: 1514739398841430622086649900n,
        amountIn: baseAmount,
        amountOutMinimum: 1,
        sqrtPriceLimitX96: 0,
      })
      .then((tx) => tx.wait());

    tick = await UniswapV3Pool.slot0().then((t) => t.tick);
    console.log(
      "After swap, tick, tickUpper, tickLower:",
      tick,
      tickUpper,
      tickLower
    );

    console.log(
      "After swap, balance of token0(MATIC), token1(WETH) :",
      ethers.formatEther(await token0.balanceOf(signer.address)),
      ethers.formatEther(await token1.balanceOf(signer.address))
    );
  }
  //Add liquidity
  console.log("Approve NonfungiblePositionManager");
  await token0
    .approve(_nonfungiblePositionManager, ethers.MaxUint256)
    .then((tx) => tx.wait());
  await token1
    .approve(_nonfungiblePositionManager, ethers.MaxUint256)
    .then((tx) => tx.wait());
  console.log("Add liquidity");

  await nonfungiblePositionManager
    .mint({
      token0: token0,
      token1: token1,
      fee: fee,
      tickLower: tickLower,
      tickUpper: tickUpper,
      amount0Desired: await token0.balanceOf(signer.address),
      amount1Desired: await token1.balanceOf(signer.address),
      amount0Min: 1,
      amount1Min: 1,
      recipient: signer.address,
      deadline: ethers.MaxUint256,
    })
    .then((tx) => tx.wait());

  console.log(
    "After add liquidity, balance of token0(MATIC), token1(WETH) :",
    ethers.formatEther(await token0.balanceOf(signer.address)),
    ethers.formatEther(await token1.balanceOf(signer.address))
  );
}

test(
  ADDRESS.POOL_MATIC_WETH,
  ADDRESS.WETH,
  ADDRESS.QUOTER,
  ADDRESS.SWAP_ROUTER,
  ADDRESS.NFTPOSITIONMANAGER,
  3000
);
