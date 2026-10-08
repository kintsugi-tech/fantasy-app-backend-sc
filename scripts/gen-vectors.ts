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

const leagueSlug = 'mvl-2026-27-main'
const matchday = 7
const canonicalGameIds = ['mvl-2026-27-000101', 'mvl-2026-27-000102', 'mvl-2026-27-000103']
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

// The round locks at 1_800_007_200: sumLeadTime below is lockTime - confirmedAt.
const players = [
  { seed: 'm2-vector-user-0', picks: [1, 2, 1] as m2.Pick[], confirmedAt: 1_800_000_000n },
  { seed: 'm2-vector-user-1', picks: [2, 2, 2] as m2.Pick[], confirmedAt: 1_800_003_600n },
  { seed: 'm2-vector-user-2', picks: [3, 1, 3] as m2.Pick[], confirmedAt: 1_800_005_400n },
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

  const csv = 'spec_version,game_id,date,home,away,home_sets,away_sets,status,forfeit_team\n' +
    'vb-1,000101,2026-11-14T19:00:00+08:00,UB_BRONCOS,ZAVKHAN_BROTHERS,3,1,final,'
  const sha256Base64 = createHash('sha256').update(csv, 'utf8').digest('base64')

  // Game 3 ends in a draw: only the draw pick of user 2 scores on it.
  const outcomes = [m2.OUTCOME.HOME, m2.OUTCOME.NOT_COUNTED, m2.OUTCOME.DRAW]
  // Users 0 and 2 tie on points and rounds; user 0 confirmed earlier, so it ranks first.
  const standings = [
    { account: submissions[0].user, rank: 1, points: 1, correct: 1, counted: 2, roundsPlayed: 1, sumLeadTime: 7_200n },
    { account: submissions[2].user, rank: 2, points: 1, correct: 1, counted: 2, roundsPlayed: 1, sumLeadTime: 1_800n },
    { account: submissions[1].user, rank: 3, points: 0, correct: 0, counted: 2, roundsPlayed: 1, sumLeadTime: 3_600n },
  ]
  // The hard-coded rows must agree with the scoring and the tie-breaks.
  const ranked = m2.rankPlayers(standings)
  for (const [i, s] of standings.entries()) {
    const score = m2.scoreRound(players[submissions.findIndex((x) => x.user === s.account)].picks, outcomes)
    if (score.correct !== s.correct || score.counted !== s.counted) throw new Error(`row ${i}: wrong score`)
    if (ranked[i].account !== s.account || ranked[i].rank !== s.rank) throw new Error(`row ${i}: wrong rank`)
  }
  const tree = StandardMerkleTree.of(
    standings.map((s) => m2.standingLeafOf(leagueId, s)),
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
      leaves: standings.map((s, i) => ({ ...s, sumLeadTime: s.sumLeadTime.toString(), proof: tree.getProof(i) })),
    },
  }

  const out = fileURLToPath(new URL('../test/vectors/m2-vectors.json', import.meta.url))
  writeFileSync(out, JSON.stringify(vectors, null, 2) + '\n')
  console.log(`wrote ${out}`)
}

await main()
