import { buildModule } from '@nomicfoundation/hardhat-ignition/modules'

/**
 * Deploys ResultsRegistry -> Predictions.
 *
 * The admin and every role holder are constructor arguments: the deploying account gets no role.
 * The deploy can therefore run from any account (for example one Injective authorized as a
 * deployer), and the admin is the cold wallet from the first block, with no hot-key window.
 *
 * Parameters: see ignition/parameters/mainnet.example.json. Admin, admin delay and role holders
 * have no default on purpose, so a deploy can never silently grant a role to a placeholder.
 * Check every deploy with scripts/check-deploy.ts.
 */
export default buildModule('M2', (m) => {
  const admin = m.getParameter<string>('admin')
  const adminDelay = m.getParameter<number>('adminDelay')
  const postponeWindow = m.getParameter<bigint>('postponeWindow', 7n * 24n * 3600n)
  const finalizationDelay = m.getParameter<bigint>('finalizationDelay', 24n * 3600n)
  const correctionWindow = m.getParameter<bigint>('correctionWindow', 24n * 3600n)

  const operator = m.getParameter<string>('operator')
  const resultsRelayer = m.getParameter<string>('resultsRelayer')
  const submitter = m.getParameter<string>('submitter')
  const steward = m.getParameter<string>('steward')

  const registry = m.contract('ResultsRegistry', [
    adminDelay,
    admin,
    postponeWindow,
    correctionWindow,
    operator,
    resultsRelayer,
    steward,
  ])
  const predictions = m.contract('Predictions', [
    adminDelay,
    admin,
    registry,
    operator,
    submitter,
    steward,
    finalizationDelay,
  ])

  return { registry, predictions }
})
