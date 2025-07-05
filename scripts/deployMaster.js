import { ethers } from "hardhat";
import { Contract } from "ethers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

async function main() {
  console.log("Deploying StableSwap Factory and dependencies...");

  // Get signers
  const [deployer] = await ethers.getSigners();
  console.log(`Deployer address: ${deployer.address}`);

  // First deploy the StableMath library
  console.log("Deploying StableMath library...");
  const StableMath = await ethers.getContractFactory("StableMath");
  const stableMath = await StableMath.deploy();
  await stableMath.deployed();
  console.log(`StableMath deployed to: ${stableMath.address}`);

  // Link the StableMath library to the factory
  const StableSwapFactory = await ethers.getContractFactory(
    "StableSwapFactory",
    {
      libraries: {
        StableMath: stableMath.address,
      },
    }
  );

  // Default protocol fee parameters
  const defaultProtocolFeeReceiver = deployer.address;
  const defaultProtocolFeeShare = 1000; // 10% in basis points

  // Default pool parameters
  const defaultA = 200 * 100; // 200 with A_PRECISION = 100
  const defaultBaseFee = 5000; // 0.05% (5000/1e6)
  const defaultMinFee = 1000; // 0.01% (1000/1e6)
  const defaultMaxFee = 100000; // 0.1% (100000/1e6)
  const defaultVolatilityMultiplier = 2000000; // 2.0 (2000000/1e6)

  // Deploy the factory
  console.log("Deploying StableSwapFactory...");
  const factory = await StableSwapFactory.deploy(
    defaultProtocolFeeReceiver,
    defaultProtocolFeeShare,
    defaultA,
    defaultBaseFee,
    defaultMinFee,
    defaultMaxFee,
    defaultVolatilityMultiplier
  );

  await factory.deployed();
  console.log(`StableSwapFactory deployed to: ${factory.address}`);

  // Verify contracts on Etherscan if not on localhost
  const networkName = (await ethers.provider.getNetwork()).name;
  if (networkName !== "unknown") {
    console.log("Waiting for block confirmations...");
    await factory.deployTransaction.wait(5); // Wait for 5 confirmations

    console.log("Verifying contracts on Etherscan...");
    await hre.run("verify:verify", {
      address: stableMath.address,
      constructorArguments: [],
    });

    await hre.run("verify:verify", {
      address: factory.address,
      constructorArguments: [
        defaultProtocolFeeReceiver,
        defaultProtocolFeeShare,
        defaultA,
        defaultBaseFee,
        defaultMinFee,
        defaultMaxFee,
        defaultVolatilityMultiplier,
      ],
    });
  }

  console.log("Deployment complete!");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
