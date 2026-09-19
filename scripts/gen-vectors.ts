/**
 * Generates test/vectors/m2-vectors.json: deterministic encodings that the Solidity tests and the
 * off-chain app (injective-m2-frontend/packages/chain) must both reproduce.
 *
 *   pnpm vectors
 */
import { createHash } from 'node:crypto'
import { writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

import { StandardMerkleTree } from '@openzeppelin/merkle-tree'
import { type Hex, hashTypedData, keccak256, stringToHex } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'

import * as m2 from './lib/m2.js'

const CHAIN_ID = 1439
const VERIFYING_CONTRACT = '0x1111111111111111111111111111111111111111' as Hex

const leagueSlug = 'mbl-2026-27-main'
const matchday = 7
const canonicalGameIds = ['mbl-2026-27-000101', 'mbl-2026-27-000102', 'mbl-2026-27-000103']
const teams = [
  ['UB_BRONCOS', 'ZAVKHAN_BROTHERS'],
  ['KHASYN_KHULUGUUD', 'DARKHAN_UNITED'],
  ['ERDENET_MINERS', 'SELENGE_BODONS'],
]

const leagueId = m2.leagueIdOf(leagueSlug)
const gameIds = canonicalGameIds.map(m2.gameIdOf)
const roundId = m2.roundIdOf(leagueId, matchday)
const gamesHash = m2.gamesHashOf(gameIds)
const domain = m2.eip712Domain(CHAIN_ID, VERIFYING_CONTRACT)

const players = [
  { seed: 'm2-vector-user-0', picks: [1, 2, 1] as m2.Pick[], confirmedAt: 1_800_000_000n },
  { seed: 'm2-vector-user-1', picks: [2, 2, 2] as m2.Pick[], confirmedAt: 1_800_003_600n },
]

async function main() {
  const submissions = await Promise.all(
    players.map(async (p) => {
      const account = privateKeyToAccount(keccak256(stringToHex(p.seed)))
      const picks = m2.encodePicks(p.picks)
      const picksHash = m2.picksHashOf(roundId, gamesHash, picks)
      const message = { user: account.address, roundId, picksHash, confirmedAt: p.confirmedAt }
      const typed = { domain, types: m2.submissionTypes, primaryType: 'Submission', message } as const
      return {
        privateKeySeed: p.seed,
        user: account.address,
        picks,
        picksHash,
        confirmedAt: p.confirmedAt.toString(),
        digest: hashTypedData(typed),
        signature: await account.signTypedData(typed),
      }
    }),
  )

  const csv = 'spec_version,game_id,date,home,away,home_score,away_score,status,ot\n' +
    'bb-1,000101,2026-11-14T19:00:00+08:00,UB_BRONCOS,ZAVKHAN_BROTHERS,88,80,final,0'
  const sha256Base64 = createHash('sha256').update(csv, 'utf8').digest('base64')

  const outcomes = [m2.OUTCOME.HOME, m2.OUTCOME.NOT_COUNTED, m2.OUTCOME.HOME]
  const standings = [
    { account: submissions[0].user, rank: 1, points: 2, correct: 2, counted: 2, roundsPlayed: 1 },
    { account: submissions[1].user, rank: 2, points: 0, correct: 0, counted: 2, roundsPlayed: 1 },
  ]
  const tree = StandardMerkleTree.of(
    standings.map((s) => [leagueId, s.account, s.rank, s.points, s.correct, s.counted, s.roundsPlayed]),
    [...m2.STANDINGS_LEAF_ENCODING],
  )

  const vectors = {
    description: 'M2 encoding vectors. Regenerate with `pnpm vectors`; never edit by hand.',
    domain: { ...domain },
    league: { slug: leagueSlug, leagueId },
    round: { matchday, roundId, canonicalGameIds, gameIds, gamesHash },
    teams: teams.map(([home, away]) => ({
      home,
      away,
      homeCode: m2.teamCodeOf(home),
      awayCode: m2.teamCodeOf(away),
    })),
    submissions,
    result: { csv, sha256Base64, sourceHash: m2.sourceHashFromBase64(sha256Base64) },
    scoring: {
      outcomes,
      scores: players.map((p) => m2.scoreRound(p.picks, outcomes)),
    },
    standings: {
      root: tree.root,
      leaves: standings.map((s, i) => ({ ...s, proof: tree.getProof(i) })),
    },
  }

  const out = fileURLToPath(new URL('../test/vectors/m2-vectors.json', import.meta.url))
  writeFileSync(out, JSON.stringify(vectors, null, 2) + '\n')
  console.log(`wrote ${out}`)
}

await main()
