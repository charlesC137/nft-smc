const hre = require("hardhat");

async function main() {
  // Use any signer you want — here we use the first signer provided by Hardhat
  const [deployer] = await hre.ethers.getSigners();

  // Show which wallet is deploying
  console.log("Deploying contract with wallet:", deployer.address);

  // Get contract factory
  const Contract = await hre.ethers.getContractFactory("NFTMarketplace");

  // Pass in the wallet address (this becomes contract owner)
  const nft = await Contract.deploy(deployer.address);

  // Wait until deployed
  await nft.waitForDeployment();

  console.log("NFTMarketplace deployed to:", await nft.getAddress());
  console.log("Contract owner:", await nft.owner());
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
