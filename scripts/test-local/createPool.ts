import { ethers } from "hardhat";
import { ERC20, IUniswapV3Factory } from "../../typechain-types";

async function createPool() {
  const Token_factory = await ethers.getContractFactory("ERC20");
  const SH_Token: ERC20 = await Token_factory.deploy("Token", "SH").then((t) =>
    t.waitForDeployment()
  );
  const SY_Token: ERC20 = await Token_factory.deploy("Token", "SY").then((t) =>
    t.waitForDeployment()
  );
  const sh: string = await SH_Token.getAddress();
  const sy: string = await SY_Token.getAddress();
  const UniswapV3Factory: IUniswapV3Factory = await ethers.getContractAt(
    "IUniswapV3Factory",
    "0x1f98431c8ad98523631ae4a59f267346ea31f984"
  );
  UniswapV3Factory.createPool(sh, sy, 3000);
}
createPool();
