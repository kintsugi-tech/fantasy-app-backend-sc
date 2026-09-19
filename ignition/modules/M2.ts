import { buildModule } from '@nomicfoundation/hardhat-ignition/modules'
import { keccak256, stringToHex } from 'viem'

const role = (name: string) => keccak256(stringToHex(name))

/**
 * Deploys ResultsRegistry -> Predictions -> LeagueBadge and grants the automation/steward roles.
 *
 * The deployer (account 0) is the initial DEFAULT_ADMIN of all three contracts. On mainnet, hand
 * admin over to the cold wallet afterwards with beginDefaultAdminTransfer / acceptDefaultAdminTransfer
 * (see README "Mainnet runbook").
 *
 * Parameters: see ignition/parameters/testnet.example.json. Role holders have no default on
 * purpose, so a deploy can never silently grant a role to a placeholder.
 */
export default buildModule('M2', (m) => {
  const admin = m.getAccount(0)

  const adminDelay = m.getParameter<number>('adminDelay', 0)
  const finalityDelay = m.getParameter<bigint>('finalityDelay', 12n * 3600n)
  const postponeWindow = m.getParameter<bigint>('postponeWindow', 7n * 24n * 3600n)
  const challengeWindow = m.getParameter<bigint>('challengeWindow', 72n * 3600n)

  const operator = m.getParameter<string>('operator')
  const resultsRelayer = m.getParameter<string>('resultsRelayer')
  const submitter = m.getParameter<string>('submitter')
  const minter = m.getParameter<string>('minter')
  const steward = m.getParameter<string>('steward')

  const registry = m.contract('ResultsRegistry', [adminDelay, admin, finalityDelay, postponeWindow])
  const predictions = m.contract('Predictions', [adminDelay, admin, registry, challengeWindow])
  const badge = m.contract('LeagueBadge', [adminDelay, admin, predictions])

  m.call(registry, 'grantRole', [role('OPERATOR_ROLE'), operator], { id: 'registry_operator' })
  m.call(registry, 'grantRole', [role('RESULTS_RELAYER_ROLE'), resultsRelayer], { id: 'registry_relayer' })
  m.call(registry, 'grantRole', [role('STEWARD_ROLE'), steward], { id: 'registry_steward' })
  m.call(predictions, 'grantRole', [role('OPERATOR_ROLE'), operator], { id: 'predictions_operator' })
  m.call(predictions, 'grantRole', [role('SUBMITTER_ROLE'), submitter], { id: 'predictions_submitter' })
  m.call(predictions, 'grantRole', [role('STEWARD_ROLE'), steward], { id: 'predictions_steward' })
  m.call(badge, 'grantRole', [role('MINTER_ROLE'), minter], { id: 'badge_minter' })
  m.call(badge, 'grantRole', [role('OPERATOR_ROLE'), operator], { id: 'badge_operator' })

  return { registry, predictions, badge }
})
