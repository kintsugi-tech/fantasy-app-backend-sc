/**
 * Reference TypeScript implementation of every M2 on-chain encoding.
 *
 * The off-chain app (injective-m2-frontend/packages/chain) must produce exactly these values;
 * test/vectors/m2-vectors.json pins them and both the Solidity and the TS tests check them.
 */
import {
  type Address,
  type Hex,
  bytesToHex,
  encodeAbiParameters,
  encodePacked,
  hexToBytes,
  keccak256,
  stringToHex,
} from 'viem'

/** Picks use the values of IResultsRegistry.Side; DRAW only makes sense where draws are allowed. */
export const PICK = { HOME: 1, AWAY: 2, DRAW: 3 } as const
export type Pick = (typeof PICK)[keyof typeof PICK]

/** Outcome of a game inside a finalized round (Predictions.Round.outcomes, 2 bits per game). */
export const OUTCOME = { NOT_COUNTED: 0, HOME: 1, AWAY: 2, DRAW: 3 } as const

/**
 * Game formats for ResultsRegistry.registerGames (GameInfo.targetScore, GameInfo.drawAllowed).
 * The scores recorded are the unit that decides the winner: points, goals or sets.
 */
export const GAME_FORMAT = {
  basketball: { targetScore: 0, drawAllowed: false }, // points
  football: { targetScore: 0, drawAllowed: true }, // goals, league match
  volleyball: { targetScore: 3, drawAllowed: false }, // sets, best of 5
  beachVolleyball: { targetScore: 2, drawAllowed: false }, // sets, best of 3
} as const
export type Sport = keyof typeof GAME_FORMAT
export type GameFormat = { targetScore: number; drawAllowed: boolean }

// --- identifiers ------------------------------------------------------------------------------

/** gameId = keccak256(bytes(canonicalGameId)), e.g. "mbl-2026-27-000123". */
export const gameIdOf = (canonicalGameId: string): Hex => keccak256(stringToHex(canonicalGameId))

/** leagueId = keccak256(bytes(slug)), e.g. "mbl-2026-27-main". */
export const leagueIdOf = (slug: string): Hex => keccak256(stringToHex(slug))

/** Team codes are bytes32 short strings (<= 31 bytes), like Solidity's bytes32("UB_BRONCOS"). */
export const teamCodeOf = (code: string): Hex => {
  if (new TextEncoder().encode(code).length > 31) throw new Error(`team code too long: ${code}`)
  return stringToHex(code, { size: 32 })
}

/** roundId = keccak256(abi.encode(leagueId, uint16 matchday)). */
export const roundIdOf = (leagueId: Hex, matchday: number): Hex =>
  keccak256(encodeAbiParameters([{ type: 'bytes32' }, { type: 'uint16' }], [leagueId, matchday]))

/** gamesHash = keccak256(abi.encodePacked(bytes32[] gameIds)). */
export const gamesHashOf = (gameIds: readonly Hex[]): Hex =>
  keccak256(encodePacked(gameIds.map(() => 'bytes32' as const), [...gameIds]))

// --- picks ------------------------------------------------------------------------------------

/** Picks schema 1: one byte per game in the round's order, 1 = home, 2 = away, 3 = draw. */
export const encodePicks = (picks: readonly Pick[]): Hex => {
  for (const p of picks) {
    if (p !== PICK.HOME && p !== PICK.AWAY && p !== PICK.DRAW) throw new Error(`invalid pick ${p}`)
  }
  return bytesToHex(Uint8Array.from(picks))
}

export const decodePicks = (picks: Hex): Pick[] => [...hexToBytes(picks)] as Pick[]

/** The receipt shown in the app: keccak256(abi.encode(roundId, gamesHash, keccak256(picks))). */
export const picksHashOf = (roundId: Hex, gamesHash: Hex, picks: Hex): Hex =>
  keccak256(
    encodeAbiParameters(
      [{ type: 'bytes32' }, { type: 'bytes32' }, { type: 'bytes32' }],
      [roundId, gamesHash, keccak256(picks)],
    ),
  )

// --- EIP-712 ----------------------------------------------------------------------------------

export const eip712Domain = (chainId: number, verifyingContract: Address) =>
  ({ name: 'M2Predictions', version: '1', chainId, verifyingContract }) as const

export const submissionTypes = {
  Submission: [
    { name: 'user', type: 'address' },
    { name: 'roundId', type: 'bytes32' },
    { name: 'picksHash', type: 'bytes32' },
    { name: 'confirmedAt', type: 'uint64' },
  ],
} as const

export type Submission = { user: Address; roundId: Hex; picksHash: Hex; confirmedAt: bigint }

// --- results ----------------------------------------------------------------------------------

/** LocalTruth stores sha256_pub as base64; the registry stores the same 32 bytes as bytes32. */
export const sourceHashFromBase64 = (sha256Base64: string): Hex => {
  const bytes = Uint8Array.from(atob(sha256Base64), (c) => c.charCodeAt(0)) // browser + Node
  if (bytes.length !== 32) throw new Error('sha256_pub must decode to 32 bytes')
  return bytesToHex(bytes)
}

// --- scoring (layer 0) ------------------------------------------------------------------------

/** Mirrors PicksLib.score: +1 per correct pick on a counted game. */
export const scoreRound = (
  picks: readonly Pick[],
  outcomes: readonly number[],
): { correct: number; counted: number } => {
  let correct = 0
  let counted = 0
  outcomes.forEach((o, i) => {
    if (o === OUTCOME.NOT_COUNTED) return
    counted++
    if (picks[i] === o) correct++
  })
  return { correct, counted }
}

/** Unpacks Predictions.Round.outcomes (2 bits per game). */
export const unpackOutcomes = (packed: bigint, gameCount: number): number[] =>
  Array.from({ length: gameCount }, (_, i) => Number((packed >> BigInt(2 * i)) & 3n))

// --- standings --------------------------------------------------------------------------------

/**
 * OZ StandardMerkleTree leaf encoding of the final standings (IPredictions.StandingLeaf; root in
 * Predictions.proposeStandings, then finalizeLeague). Predictions.checkStanding verifies a row.
 */
export const STANDINGS_LEAF_ENCODING = [
  'bytes32', // leagueId
  'address', // account
  'uint32', // rank
  'uint32', // points
  'uint32', // correct
  'uint32', // counted
  'uint16', // roundsPlayed
  'uint64', // sumLeadTime: the third tie-break
] as const

/** A ranked player as a standings leaf, in STANDINGS_LEAF_ENCODING order. */
export const standingLeafOf = (
  leagueId: Hex,
  p: PlayerStats & { rank: number },
): [Hex, Address, number, number, number, number, number, bigint] => [
  leagueId,
  p.account,
  p.rank,
  p.points,
  p.correct,
  p.counted,
  p.roundsPlayed,
  p.sumLeadTime,
]

export type PlayerStats = {
  account: Address
  points: number
  correct: number
  counted: number
  roundsPlayed: number
  sumLeadTime: bigint
}

/**
 * Tie-break order: points, then rounds played, then average lead time before the lock
 * (earlier confirmation wins). Players still tied share the rank (standard competition
 * ranking, "1224"); the final verifiable draw for prizes happens off-chain on top of this.
 */
export const rankPlayers = (players: readonly PlayerStats[]): (PlayerStats & { rank: number })[] => {
  const avgLead = (p: PlayerStats) =>
    p.roundsPlayed === 0 ? 0n : p.sumLeadTime / BigInt(p.roundsPlayed)
  const cmp = (a: PlayerStats, b: PlayerStats) =>
    b.points - a.points ||
    b.roundsPlayed - a.roundsPlayed ||
    (avgLead(b) > avgLead(a) ? 1 : avgLead(b) < avgLead(a) ? -1 : 0)
  const sorted = [...players].sort(cmp)
  return sorted.map((p, i) => {
    let rank = i + 1
    while (rank > 1 && cmp(sorted[rank - 2], p) === 0) rank--
    return { ...p, rank }
  })
}
