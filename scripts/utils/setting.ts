import { ethers } from "hardhat";
import {
  INonfungiblePositionManager,
  IQuoterV2,
  ISwapRouter,
  IUniswapV3Pool,
  IWETH9,
} from "../../typechain-types";

const setting = async (
  _pool: string,
  _weth: string,
  _quoter: string,
  _swapRouter: string,
  _nonfungiblePositionManager: string
) => {
  const UniswapV3Pool: IUniswapV3Pool = await ethers.getContractAt(
    "IUniswapV3Pool",
    _pool
  );

  const token0_address: string = await UniswapV3Pool.token0(); // MATIC:  "0x7D1AfA7B718fb893dB30A3aBc0Cfc608AaCfeBB0"
  const token1_address: string = await UniswapV3Pool.token1(); // WETH:  "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
  const token0 = await ethers.getContractAt("IERC20", token0_address);
  const token1 = await ethers.getContractAt("IERC20", token1_address);
  const [signer] = await ethers.getSigners();

  const WETH: IWETH9 = await ethers.getContractAt("IWETH9", _weth);
  await WETH.deposit({ value: ethers.parseEther("1000") }).then((tx) =>
    tx.wait()
  ); // WETH:2000

  //Set SwapRouter
  const SwapRouter: ISwapRouter = await ethers.getContractAt(
    "ISwapRouter",
    _swapRouter
  );

  // Set NonfungiblePositionManager
  const NonfungiblePositionManager: INonfungiblePositionManager =
    await ethers.getContractAt(
      "INonfungiblePositionManager",
      _nonfungiblePositionManager
    );

  const tick = await UniswapV3Pool.slot0().then((t) => t.tick);

  const Quoter: IQuoterV2 = await ethers.getContractAt("IQuoterV2", _quoter);

  return {
    signer,
    SwapRouter,
    Quoter,
    NonfungiblePositionManager,
    UniswapV3Pool,
    WETH,
    tick,
    token0,
    token1,
  };
};

export default setting;
