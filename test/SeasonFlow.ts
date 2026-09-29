import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { describe, it } from 'node:test'

import { StandardMerkleTree } from '@openzeppelin/merkle-tree'
import { network } from 'hardhat'
import { type Hex, hashTypedData, keccak256, parseEventLogs, stringToHex } from 'viem'
import {
  english,
  generateMnemonic,
  generatePrivateKey,
  mnemonicToAccount,
  privateKeyToAccount,
  type LocalAccount,
} from 'viem/accounts'

import * as m2 from '../scripts/lib/m2.js'

const HOUR = 3600
const POSTPONE = 7 * 24 * HOUR

describe('M2 season flow', async () => {
  const { viem, networkHelpers } = await network.create()
  const publicClient = await viem.getPublicClient()
  const [admin, operator, resultsRelayer, submitter, steward, anyone] = await viem.getWalletClients()
  const chainId = await publicClient.getChainId()

  async function deployM2() {
    const registry = await viem.deployContract('ResultsRegistry', [0, admin.account.address, BigInt(POSTPONE)])
    const predictions = await viem.deployContract('Predictions', [0, admin.account.address, registry.address])

    await registry.write.grantRole([await registry.read.OPERATOR_ROLE(), operator.account.address])
    await registry.write.grantRole([await registry.read.RESULTS_RELAYER_ROLE(), resultsRelayer.account.address])
    await registry.write.grantRole([await registry.read.STEWARD_ROLE(), steward.account.address])
    await predictions.write.grantRole([await predictions.read.OPERATOR_ROLE(), operator.account.address])
    await predictions.write.grantRole([await predictions.read.SUBMITTER_ROLE(), submitter.account.address])
    await predictions.write.grantRole([await predictions.read.STEWARD_ROLE(), steward.account.address])
    return { registry, predictions }
  }

  /** Registers games, creates the league and schedules one round opening one hour ago. */
  async function setupRound(
    c: Awaited<ReturnType<typeof deployM2>>,
    slug: string,
    gameCount: number,
  ) {
    const now = await networkHelpers.time.latest()
    const lockTime = BigInt(now + 24 * HOUR)
    const games = Array.from({ length: gameCount }, (_, i) => ({
      gameId: m2.gameIdOf(`${slug}-${String(i + 1).padStart(6, '0')}`),
      homeTeam: m2.teamCodeOf(`HOME_${i}`),
      awayTeam: m2.teamCodeOf(`AWAY_${i}`),
      tipOff: lockTime + BigInt(i * HOUR),
    }))
    await c.registry.write.registerGames([games], { account: operator.account })

    const leagueId = m2.leagueIdOf(slug)
    await c.predictions.write.createLeague([leagueId, keccak256(stringToHex('metadata'))], {
      account: operator.account,
    })
    const gameIds = games.map((g) => g.gameId)
    await c.predictions.write.scheduleRound([leagueId, 1, BigInt(now - HOUR), lockTime, gameIds], {
      account: operator.account,
    })
    return { leagueId, roundId: m2.roundIdOf(leagueId, 1), games, gameIds, lockTime, now }
  }

  /** What the worker does at "Confirm": sign the EIP-712 Submission with the custodial key. */
  async function signSubmission(
    predictionsAddress: Hex,
    account: LocalAccount,
    roundId: Hex,
    gamesHash: Hex,
    picks: m2.Pick[],
    confirmedAt: bigint,
  ) {
    const encoded = m2.encodePicks(picks)
    const picksHash = m2.picksHashOf(roundId, gamesHash, encoded)
    const typed = {
      domain: m2.eip712Domain(chainId, predictionsAddress),
      types: m2.submissionTypes,
      primaryType: 'Submission',
      message: { user: account.address, roundId, picksHash, confirmedAt },
    } as const
    return {
      item: {
        user: account.address,
        picksHash,
        picks: encoded,
        confirmedAt,
        signature: await account.signTypedData(typed),
      },
      digest: hashTypedData(typed),
    }
  }

  it('matches the shared encoding vectors', async () => {
    const vectors = JSON.parse(
      readFileSync(new URL('./vectors/m2-vectors.json', import.meta.url), 'utf8'),
    )
    assert.equal(m2.leagueIdOf(vectors.league.slug), vectors.league.leagueId)
    assert.deepEqual(vectors.round.canonicalGameIds.map(m2.gameIdOf), vectors.round.gameIds)
    assert.equal(m2.roundIdOf(vectors.league.leagueId, vectors.round.matchday), vectors.round.roundId)
    assert.equal(m2.gamesHashOf(vectors.round.gameIds), vectors.round.gamesHash)
    assert.equal(m2.sourceHashFromBase64(vectors.result.sha256Base64), vectors.result.sourceHash)
    for (const s of vectors.submissions) {
      assert.equal(m2.picksHashOf(vectors.round.roundId, vectors.round.gamesHash, s.picks), s.picksHash)
      const account = privateKeyToAccount(keccak256(stringToHex(s.privateKeySeed)))
      assert.equal(account.address, s.user)
    }
  })

  it('runs a full league: fixtures, signed batch, results, scoring, standings', async () => {
    const c = await deployM2()
    const { leagueId, roundId, games, gameIds, lockTime, now } = await setupRound(c, 'mbl-2026-27', 4)
    const gamesHash = m2.gamesHashOf(gameIds)

    const round = await c.predictions.read.getRound([roundId])
    assert.equal(round.gamesHash, gamesHash)

    // Custodial wallets: one BIP39 mnemonic per user, m/44'/60'/0'/0/0 (the same key is the inj1 address).
    const users = Array.from({ length: 4 }, () => mnemonicToAccount(generateMnemonic(english)))
    const picks: m2.Pick[][] = [
      [1, 2, 1, 1],
      [2, 2, 2, 2],
      [1, 1, 1, 1],
      [1, 2, 1, 2],
    ]

    const signed = await Promise.all(
      users.map((u, i) =>
        signSubmission(c.predictions.address, u, roundId, gamesHash, picks[i], BigInt(now - 600 * (i + 1))),
      ),
    )
    // TS and Solidity agree on picksHash and on the EIP-712 digest.
    for (const [i, s] of signed.entries()) {
      assert.equal(await c.predictions.read.computePicksHash([roundId, s.item.picks]), s.item.picksHash)
      assert.equal(
        await c.predictions.read.submissionDigest([users[i].address, roundId, s.item.picksHash, s.item.confirmedAt]),
        s.digest,
      )
    }

    const batch = signed.map((s) => s.item)
    const tx = await c.predictions.write.submitForBatch([roundId, batch], { account: submitter.account })
    const receipt = await publicClient.waitForTransactionReceipt({ hash: tx })
    const submittedLogs = parseEventLogs({ abi: c.predictions.abi, logs: receipt.logs, eventName: 'PredictionSubmitted' })
    assert.equal(submittedLogs.length, 4)

    // Retrying the same batch is harmless (all duplicates, nothing changes).
    await c.predictions.write.submitForBatch([roundId, batch], { account: submitter.account })
    assert.equal((await c.predictions.read.getRound([roundId])).submissions, 4)

    // Games are played; MSC files are attested on LocalTruth; the relayer records them.
    await networkHelpers.time.increaseTo(Number(lockTime) + 6 * HOUR)
    const homeWins = [true, false, true, false]
    const results = games.map((g, i) => {
      const csv = `spec_version,game_id,home,away,home_score,away_score,status,ot\nbb-1,${i},H,A,${homeWins[i] ? '90,80' : '80,90'},final,0`
      const sha256Base64 = createHash('sha256').update(csv, 'utf8').digest('base64')
      const sourceHash = m2.sourceHashFromBase64(sha256Base64)
      assert.equal(sourceHash, `0x${createHash('sha256').update(csv, 'utf8').digest('hex')}`)
      return {
        gameId: g.gameId,
        homeTeam: g.homeTeam,
        awayTeam: g.awayTeam,
        status: 2, // Final
        winner: homeWins[i] ? 1 : 2,
        homeScore: homeWins[i] ? 90 : 80,
        awayScore: homeWins[i] ? 80 : 90,
        overtimes: 0,
        sourceHash,
        attestationId: `mbl_2026_game-${i}`,
      }
    })
    await c.registry.write.recordResults([results.slice(0, 3)], { account: resultsRelayer.account })

    // A round settles only once every game has a result; results are final as soon as recorded.
    await viem.assertions.revertWithCustomErrorWithArgs(
      c.predictions.write.finalizeRound([roundId], { account: anyone.account }),
      c.predictions,
      'GameNotFinal',
      [gameIds[3]],
    )
    await c.registry.write.recordResults([results.slice(3)], { account: resultsRelayer.account })
    await c.predictions.write.finalizeRound([roundId], { account: anyone.account })

    // Scores from the chain equal the TS mirror of the scoring rules.
    const finalized = await c.predictions.read.getRound([roundId])
    const outcomes = m2.unpackOutcomes(finalized.outcomes, finalized.gameCount)
    assert.deepEqual(outcomes, [1, 2, 1, 2])
    for (const [i, u] of users.entries()) {
      const [correct, counted] = await c.predictions.read.scoreOf([roundId, u.address])
      assert.deepEqual({ correct, counted }, m2.scoreRound(picks[i], outcomes))
    }

    // Standings: stats from the chain, ranked with the tie-breaks, anchored as a Merkle root.
    const stats = await Promise.all(
      users.map(async (u) => ({ account: u.address, ...(await c.predictions.read.leagueStatsOf([leagueId, u.address])) })),
    )
    const ranked = m2.rankPlayers(stats)
    // Points: user3 4, user0 3, user1 2, user2 2. Users 1 and 2 tie on points and rounds played;
    // user 2 confirmed earlier (now - 1800 vs now - 1200), so the lead-time tie-break puts it ahead.
    assert.deepEqual(
      ranked.map((p) => [p.account, p.rank]),
      [
        [users[3].address, 1],
        [users[0].address, 2],
        [users[2].address, 3],
        [users[1].address, 4],
      ],
    )

    const tree = StandardMerkleTree.of(
      ranked.map((p) => [leagueId, p.account, p.rank, p.points, p.correct, p.counted, p.roundsPlayed]),
      [...m2.STANDINGS_LEAF_ENCODING],
    )
    const report = JSON.stringify(tree.dump())
    await c.predictions.write.finalizeLeague(
      [leagueId, tree.root as Hex, ranked.length, keccak256(stringToHex(report)), 'https://m2.example/reports/mbl.json'],
      { account: steward.account },
    )

    // Anchored once: anyone can check a player's standing against the on-chain root.
    const league = await c.predictions.read.getLeague([leagueId])
    assert.equal(league.standingsRoot, tree.root)
    const top = ranked[0]
    assert.ok(
      StandardMerkleTree.verify(
        league.standingsRoot,
        [...m2.STANDINGS_LEAF_ENCODING],
        [leagueId, top.account, top.rank, top.points, top.correct, top.counted, top.roundsPlayed],
        tree.getProof(0),
      ),
    )
    await viem.assertions.revertWithCustomErrorWithArgs(
      c.predictions.write.finalizeLeague(
        [leagueId, tree.root as Hex, ranked.length, keccak256(stringToHex(report)), 'https://m2.example/reports/mbl.json'],
        { account: steward.account },
      ),
      c.predictions,
      'LeagueNotActive',
      [leagueId],
    )
  })

  it('keeps a 50-submission batch within the gas budget', async () => {
    const c = await deployM2()
    const { roundId, gameIds, now } = await setupRound(c, 'gas-league', 10)
    const gamesHash = m2.gamesHashOf(gameIds)
    const accounts = Array.from({ length: 50 }, () => privateKeyToAccount(generatePrivateKey()))
    const picks: m2.Pick[] = [1, 2, 1, 2, 1, 2, 1, 2, 1, 2]
    const items = await Promise.all(
      accounts.map(async (a) => (await signSubmission(c.predictions.address, a, roundId, gamesHash, picks, BigInt(now))).item),
    )

    const hash = await c.predictions.write.submitForBatch([roundId, items], { account: submitter.account })
    const { gasUsed } = await publicClient.waitForTransactionReceipt({ hash })
    console.log(`      submitForBatch x50 (10 games): ${gasUsed} gas, ${gasUsed / 50n} per submission`)
    assert.ok(gasUsed < 5_000_000n, `batch used ${gasUsed} gas`)
    assert.ok(gasUsed / 50n < 60_000n, `per-submission gas ${gasUsed / 50n}`)
  })
})
