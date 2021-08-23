// In order to deploy to Goerli, first make sure to add the right IDs in the builder.config.js file

const { readArtifact } = require("@nomiclabs/buidler/plugins");

async function main() {
  const [deployer] = await ethers.getSigners();

  console.log(
    "Deploying contracts with the account:",
    await deployer.getAddress(),
  );

  console.log("Account balance:", (await deployer.getBalance()).toString());

  const contractArtifact = await readArtifact(
    "./artifacts/0.7.x",
    "MultipleArbitrableTransactionWithAppeals",
  );
  const MultipleArbitrableTransaction = await ethers.getContractFactory(
    contractArtifact.abi,
    contractArtifact.bytecode,
  );
  const contract = await MultipleArbitrableTransaction.deploy(
    "0xF2bD5519C747ADbf115F0b682897E09e51042964",
    "0x85",
    100,
    5000,
    2000,
    8000,
  );
  await contract.deployed();

  console.log("Contract address:", contract.address);
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
