import 'dotenv/config'
import hardhatToolboxViemPlugin from '@nomicfoundation/hardhat-toolbox-viem'
import hardhatVerify from '@nomicfoundation/hardhat-verify'
import { configVariable, defineConfig } from 'hardhat/config'

const compiler = {
  version: '0.8.28',
  settings: {
    evmVersion: 'cancun',
    optimizer: { enabled: true, runs: 200 },
  },
}

export default defineConfig({
  plugins: [hardhatToolboxViemPlugin, hardhatVerify],
  solidity: {
    // `production` (used by the deploy scripts) is identical to `default` (used by the tests) on
    // purpose: the bytecode that goes on-chain is the bytecode the test suite ran against.
    profiles: {
      default: compiler,
      production: compiler,
    },
  },
  test: {
    solidity: {
      // Solidity tests read the shared EIP-712 / picksHash vectors (test/vectors/*.json).
      fsPermissions: { readDirectory: ['./test/vectors'] },
      fuzz: { runs: 512 },
      invariant: { runs: 256, depth: 64, failOnRevert: false },
    },
  },
  networks: {
    // `pnpm hardhat node` (chainId 31337) for the off-chain app's end-to-end tests.
    localhost: {
      type: 'http',
      chainType: 'l1',
      url: 'http://127.0.0.1:8545',
    },
    // Injective EVM testnet. Use the sentry endpoint: the k8s.* endpoint returns null
    // receipts for mined txs, which makes Ignition report deploys as "dropped".
    injectiveTestnet: {
      type: 'http',
      chainType: 'l1',
      url: configVariable('INJECTIVE_TESTNET_RPC_URL'),
      chainId: 1439,
      accounts: [configVariable('INJECTIVE_TESTNET_DEPLOYER_KEY')],
    },
    // Keep the mainnet deployer key in the encrypted keystore, not in .env:
    //   pnpm hardhat keystore set INJECTIVE_MAINNET_DEPLOYER_KEY
    // The deployer gets no role (see ignition/modules/M2.ts): it only pays for the deploy.
    injectiveMainnet: {
      type: 'http',
      chainType: 'l1',
      url: configVariable('INJECTIVE_MAINNET_RPC_URL'),
      chainId: 1776,
      accounts: [configVariable('INJECTIVE_MAINNET_DEPLOYER_KEY')],
    },
  },
  // Hardhat 3 resolves explorers from chainDescriptors (keyed by chainId). Injective uses
  // Blockscout (no API key, no Sourcify).
  chainDescriptors: {
    1439: {
      name: 'Injective EVM Testnet',
      blockExplorers: {
        blockscout: {
          name: 'Injective Testnet Blockscout',
          url: 'https://testnet.blockscout.injective.network/',
          apiUrl: 'https://testnet.blockscout-api.injective.network/api',
        },
      },
    },
    1776: {
      name: 'Injective EVM',
      blockExplorers: {
        blockscout: {
          name: 'Injective Blockscout',
          url: 'https://blockscout.injective.network/',
          // TODO(F6): confirm the mainnet Blockscout API host before the first mainnet verify.
          apiUrl: 'https://blockscout-api.injective.network/api',
        },
      },
    },
  },
  verify: {
    blockscout: { enabled: true },
    sourcify: { enabled: false },
  },
})
