/**
 * Checks a deployment against its Ignition parameters, read-only. Run it after every deploy,
 * and always when someone else deployed for us:
 *
 *   M2_PARAMS=ignition/parameters/mainnet.json pnpm hardhat run --network injectiveMainnet scripts/check-deploy.ts
 *
 * Addresses, deployer and deployment block come from the Ignition journal of the chain. Without a
 * journal (a deploy run by a third party) pass them: M2_REGISTRY, M2_PREDICTIONS, M2_DEPLOYER,
 * M2_FROM_BLOCK. M2_LOG_STEP (default 10000) bounds each eth_getLogs range.
 *
 * Exits with code 1 if anything differs: the admin, its delay, every role holder, the parameters,
 * and that no address outside the parameters (the deployer included) holds any role.
 */
import { existsSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import { network } from 'hardhat'
import { type Address, type Hex, getAddress, keccak256, parseAbiItem, stringToHex, zeroAddress, zeroHash } from 'viem'

const root = fileURLToPath(new URL('..', import.meta.url))
const role = (name: string) => keccak256(stringToHex(name))

const { viem } = await network.getOrCreate()
const client = await viem.getPublicClient()
const chainId = await client.getChainId()

// --- inputs -------------------------------------------------------------------------------

const paramsFile = process.env.M2_PARAMS
if (!paramsFile) throw new Error('set M2_PARAMS to the Ignition parameters file used for the deploy')
const raw = JSON.parse(readFileSync(path.resolve(root, paramsFile), 'utf8')).M2 as Record<string, string | number>
const bigintParam = (name: string, fallback: bigint) => {
  const v = raw[name]
  return v === undefined ? fallback : BigInt(String(v).replace(/n$/, ''))
}
const p = {
  admin: getAddress(String(raw.admin)),
  adminDelay: BigInt(raw.adminDelay),
  postponeWindow: bigintParam('postponeWindow', 7n * 24n * 3600n),
  finalizationDelay: bigintParam('finalizationDelay', 24n * 3600n),
  operator: getAddress(String(raw.operator)),
  resultsRelayer: getAddress(String(raw.resultsRelayer)),
  submitter: getAddress(String(raw.submitter)),
  steward: getAddress(String(raw.steward)),
}

const deploymentDir = path.join(root, `ignition/deployments/chain-${chainId}`)
const journal = existsSync(path.join(deploymentDir, 'journal.jsonl'))
  ? readFileSync(path.join(deploymentDir, 'journal.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l))
  : []
const deployed = existsSync(path.join(deploymentDir, 'deployed_addresses.json'))
  ? (JSON.parse(readFileSync(path.join(deploymentDir, 'deployed_addresses.json'), 'utf8')) as Record<string, string>)
  : {}

const addressOf = (env: string, futureId: string): Address => {
  const value = process.env[env] ?? deployed[futureId]
  if (!value) throw new Error(`no ${futureId} address: set ${env} or keep the Ignition journal`)
  return getAddress(value)
}
const registryAddress = addressOf('M2_REGISTRY', 'M2#ResultsRegistry')
const predictionsAddress = addressOf('M2_PREDICTIONS', 'M2#Predictions')

const deployerRaw =
  process.env.M2_DEPLOYER ?? journal.find((e) => e.type === 'DEPLOYMENT_EXECUTION_STATE_INITIALIZE')?.from
const deployer = deployerRaw ? getAddress(deployerRaw) : undefined

const confirmedBlocks = journal
  .filter((e) => e.type === 'TRANSACTION_CONFIRM')
  .map((e) => BigInt(e.receipt.blockNumber))
const fromBlock = process.env.M2_FROM_BLOCK
  ? BigInt(process.env.M2_FROM_BLOCK)
  : confirmedBlocks.length
    ? confirmedBlocks.reduce((a, b) => (a < b ? a : b))
    : undefined

// --- checks ---------------------------------------------------------------------------------

let failures = 0
const check = (ok: boolean, what: string) => {
  console.log(`${ok ? 'ok  ' : 'FAIL'}  ${what}`)
  if (!ok) failures++
}

const registry = await viem.getContractAt('ResultsRegistry', registryAddress)
const predictions = await viem.getContractAt('Predictions', predictionsAddress)

const expectedRoles = {
  ResultsRegistry: {
    DEFAULT_ADMIN_ROLE: p.admin,
    OPERATOR_ROLE: p.operator,
    RESULTS_RELAYER_ROLE: p.resultsRelayer,
    STEWARD_ROLE: p.steward,
  },
  Predictions: {
    DEFAULT_ADMIN_ROLE: p.admin,
    OPERATOR_ROLE: p.operator,
    SUBMITTER_ROLE: p.submitter,
    STEWARD_ROLE: p.steward,
  },
} as const
const roleIdOf = (name: string): Hex => (name === 'DEFAULT_ADMIN_ROLE' ? zeroHash : role(name))
const roleNames = ['DEFAULT_ADMIN_ROLE', 'OPERATOR_ROLE', 'RESULTS_RELAYER_ROLE', 'SUBMITTER_ROLE', 'STEWARD_ROLE']
const roleNameOf = (id: string) => roleNames.find((n) => roleIdOf(n) === id) ?? id

console.log(`chain ${chainId}: ResultsRegistry ${registryAddress}, Predictions ${predictionsAddress}`)

for (const [name, contract] of [
  ['ResultsRegistry', registry],
  ['Predictions', predictions],
] as const) {
  check((await contract.read.defaultAdmin()) === p.admin, `${name}: admin is ${p.admin}`)
  check(BigInt(await contract.read.defaultAdminDelay()) === p.adminDelay, `${name}: admin delay is ${p.adminDelay} s`)
  const [pendingAdmin] = await contract.read.pendingDefaultAdmin()
  check(pendingAdmin === zeroAddress, `${name}: no admin transfer pending`)
  check(!(await contract.read.paused()), `${name}: not paused`)

  // Every known address holds exactly the roles the parameters give it.
  const known = new Set<Address>([p.admin, p.operator, p.resultsRelayer, p.submitter, p.steward])
  if (deployer) known.add(deployer)
  for (const [roleName, holder] of Object.entries(expectedRoles[name])) {
    for (const account of known) {
      const has = await contract.read.hasRole([roleIdOf(roleName), account])
      if (account === holder) check(has, `${name}: ${account} holds ${roleName}`)
      else if (has) check(false, `${name}: ${account} must not hold ${roleName}`)
    }
  }
}

check(getAddress(await predictions.read.registry()) === registryAddress, 'Predictions reads this ResultsRegistry')
check((await registry.read.postponeWindow()) === p.postponeWindow, `postponeWindow is ${p.postponeWindow} s`)
check(
  (await predictions.read.finalizationDelay()) === p.finalizationDelay,
  `finalizationDelay is ${p.finalizationDelay} s`,
)
if (deployer) {
  console.log(`note  deployer ${deployer} checked above: it holds only what the parameters give it`)
} else {
  console.log('note  deployer unknown (no journal, no M2_DEPLOYER): only the parameters were checked')
}

// Nobody outside the parameters holds a role: replay every grant and revoke since the deploy.
if (fromBlock === undefined) {
  console.log('note  no deployment block (no journal, no M2_FROM_BLOCK): role events not scanned')
} else {
  const granted = parseAbiItem('event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender)')
  const revoked = parseAbiItem('event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender)')
  const step = BigInt(process.env.M2_LOG_STEP ?? 10_000)
  const latest = await client.getBlockNumber()
  for (const [name, address] of [
    ['ResultsRegistry', registryAddress],
    ['Predictions', predictionsAddress],
  ] as const) {
    const holders = new Map<string, boolean>()
    for (let from = fromBlock; from <= latest; from += step) {
      const to = from + step - 1n < latest ? from + step - 1n : latest
      const logs = await client.getLogs({ address, events: [granted, revoked], fromBlock: from, toBlock: to })
      for (const log of logs) {
        holders.set(`${log.args.role}:${getAddress(log.args.account!)}`, log.eventName === 'RoleGranted')
      }
    }
    const expected = new Set(
      Object.entries(expectedRoles[name]).map(([roleName, holder]) => `${roleIdOf(roleName)}:${holder}`),
    )
    const current = [...holders].filter(([, has]) => has).map(([key]) => key)
    const unexpected = current.filter((key) => !expected.has(key))
    check(
      unexpected.length === 0 && current.length === expected.size,
      `${name}: ${current.length} role grants since block ${fromBlock}, all in the parameters` +
        (unexpected.length
          ? ` (unexpected: ${unexpected.map((k) => `${roleNameOf(k.split(':')[0])} → ${k.split(':')[1]}`).join(', ')})`
          : ''),
    )
  }
}

if (failures) {
  console.log(`\n${failures} check(s) failed`)
  process.exitCode = 1
} else {
  console.log('\nall checks passed')
}
