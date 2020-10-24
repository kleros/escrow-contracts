const { usePlugin, task } = require('@nomiclabs/buidler/config')

usePlugin('@nomiclabs/buidler-waffle')
usePlugin('@nomiclabs/buidler-ethers')
usePlugin('@nomiclabs/buidler-web3')

// Set the following variables if you want to deploy the contracts for testing using goerli
const GOERLI_PRIVATE_KEY = ""
const GOERLI_INFURA_PROJECT_ID = ""

// This is a sample Buidler task. To learn how to create your own go to
// https://buidler.dev/guides/create-task.html
task('accounts', 'Prints the list of accounts', async (_, { ethers }) => {
  const accounts = await ethers.getSigners()

  for (const account of accounts) {
    console.log(await account.getAddress())
  }
})

// You have to export an object to set up your config
// This object can have the following optional entries:
// defaultNetwork, networks, solc, and paths.
// Go to https://buidler.dev/config/ to learn more
module.exports = {
  // This is a sample solc configuration that specifies which version of solc to use
  solc: {
    version: '0.7.1',
    optimizer: {
      enabled: true,
      runs: 200
    }
  },
  paths: {
    sources: './contracts/0.7.x',
    cache: 'cache/0.7.x',
    artifacts: 'artifacts/0.7.x'
  },
  networks: {
    goerli: {
      url: `https://goerli.infura.io/v3/${GOERLI_INFURA_PROJECT_ID}`,
      accounts: [`0x${GOERLI_PRIVATE_KEY}`]
    }
  }
}
