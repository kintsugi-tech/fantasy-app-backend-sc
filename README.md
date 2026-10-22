# injective-m2-backend

Smart contracts for M2, the free-to-play prediction game on the Mongolian volleyball league, on
**Injective EVM** (chainId 1439 testnet, 1776 mainnet). Off-chain code (PWA, admin, API, worker)
lives in `injective-m2-frontend`.

| Contract          | Role                                                                                                                                                                                                |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ResultsRegistry` | Per-game fixtures and results. Results come from LocalTruth attestations (CosmWasm); `sourceHash` is the attested file's SHA-256. The steward can correct a result once, within `correctionWindow`. |
| `Predictions`     | Leagues, rounds (matchdays), users' signed predictions, round settlement, on-chain layer-0 scoring, final standings root (proposed, anchored once 48 h later).                                      |

## How it works

```
operator:  registerGames ─▶ createLeague ─▶ scheduleRound(leagueId, matchday, opensAt, lockTime, gameIds)
user:      "Confirm" in the app ─▶ worker signs EIP-712 Submission with the user's custodial key
submitter: submitForBatch(roundId, items)            (≤ 100 per tx, ~40k gas each; we pay the gas)
relayer:   recordResults(...)                        (after the start and the LocalTruth attestation)
steward:   correctResult(result, reason)             (once per game, within correctionWindow, 24 h,
                                                      of its result; restarts the round's delay)
anyone:    finalizeRound(roundId)                    (finalizationDelay, 24 h, after the round's last
                                                      result and once none can be corrected:
                                                      snapshots outcomes)
anyone:    scoreOf / leagueStatsOf                   (layer-0 score recomputed on-chain)
steward:   proposeStandings(root, ...)               (Merkle root of the final standings, replaceable;
                                                      the league takes no new round from then on)
anyone:    checkStanding(leaf, proof)                (a row against the root and against the chain)
steward:   finalizeLeague(leagueId)                  (48 h after the proposal, write-once)
```

Key rules:

- **One submission per user per round**, immutable, accepted only while the round is open.
  `submitFor`/`submitForBatch` are restricted to `SUBMITTER_ROLE`: users never send transactions,
  and a user who exported their key cannot bypass the app's lock.
- **Picks schema 1**: one byte per game in round order, `1` home / `2` away / `3` draw, all games
  required. Stored packed (2 bits/game), in clear: scores are verifiable by anyone. A draw pick is
  accepted on any game but can only score where the registry allows draws (the app offers it
  only there).
- `picksHash = keccak256(abi.encode(roundId, gamesHash, keccak256(picks)))` is recomputed by the
  contract; it is the receipt the app shows.
- `confirmedAt` (signed by the user) must be in `[opensAt, lockTime)` and at most `MAX_CLOCK_SKEW`
  (60 s) ahead of the block time. `submitFor` reverts on an invalid item (`SubmissionRejected`);
  `submitForBatch` skips it (`SubmissionSkipped` event plus a status per item), so a retried batch
  is harmless. The signature is checked with `ECDSA.tryRecover` (no malleable signatures).
- Limits: 32 games per round (2-bit packing in a `uint64`), 64 rounds per league, 100 items per
  batch (`registerGames`, `recordResults`, `submitForBatch`). A round's game list is immutable and
  its id is never reused, so a signature can never be replayed onto other games.
- A game counts in a round only if it was `Final`/`Forfeit` and did not start before the lock.
  `registerGames` takes only future start times (`StartTimeInPast`), and `rescheduleGame` only moves
  a game that has not started yet, to a future time: once its start time has passed it never moves
  again (`GameAlreadyStarted`), and from that same instant it takes a result. So at the lock the
  games that can count in a round are fixed: one that started before the lock never comes back
  (picks confirmed after it was played would score on it), one that starts after can only move
  later. Only a void removes a game afterwards.
- **Postponements.** Known before the start: `rescheduleGame` to the new date. Known after it: the
  start time stays; the replay's result is recorded on the same game id and counts in the round,
  with the same score as if the date had moved. Until then nothing on-chain refuses an early
  result for that game, so the worker must not record a `void` for a game that is only postponed:
  past `correctableUntil` the replay could no longer be recorded. A replay that should count in a
  later round needs a new game id (a started game cannot be scheduled again).
- `updateRoundLock` only moves a lock to at least `MIN_LOCK_NOTICE` (15 min) from now, so the
  submitter has time to land the picks already confirmed for the round. The trade-off: a game moved
  to start sooner than that cannot keep its round's lock before it, so it does not count there.
- Home/away teams are registered with the fixture; `recordResults` rejects a swapped file.
- **Results can be corrected once, by the steward.** They come from an accredited institutional
  source (MSC, attested on LocalTruth), so there is no challenge period: the relayer writes the
  first attested result. No result is accepted before the start, `Void` included. The risk is a
  relayer bug (e.g. a row matched to the wrong game, home and away sets swapped) that the on-chain
  checks do not catch, or a wrong attestation. The remedy is `correctResult`:
  - once per game, within `correctionWindow` (24 h, admin-settable between 1 h and 7 days) of
    its result; the deadline is fixed when the result is written, so a later change of the window
    never reopens it;
  - same checks as `recordResults`; the source may be the same attested file (parser bug) or a
    new one; `ResultCorrected` carries both the result and the steward's reason;
  - it also turns a void (by the relayer or `voidGame`) into a result;
  - it moves `recordedAt` to now, so every round of the game gives the corrected result a full
    `finalizationDelay`.

  A round settles only `finalizationDelay` (24 h, admin-settable between 1 h and 7 days) after its
  last result **and** once none of its results can be corrected (`correctableUntil`), whatever the
  two windows are set to: a settled round never misses a correction. If the correction is wrong
  too, or the window has closed, the steward can still cancel the round before it settles (see
  "Pause and incidents").

- A game with no result `postponeWindow` (7 days, admin-settable between 1 and 30 days) after its
  start can be voided by the steward, so a round is never blocked by a game that is never played nor
  uploaded. As a started game never moves, that date is fixed once the start has passed. It is a
  minimum, not a deadline: until the steward voids it, a late replay is still recorded and counts.
- **Final standings in two steps.** The steward proposes the root once every round of the league is
  finalized or cancelled (at least one finalized); a new proposal replaces it and restarts the 48 h
  review. During the review `checkStanding` verifies any row against the proposed root and against
  `leagueStatsOf`, so a wrong row is provable on-chain. From the first proposal on, `scheduleRound`
  refuses new rounds for the league (`StandingsAlreadyProposed`): the season is over, and the
  operator key cannot hold up `finalizeLeague`. The review starts only when the steward proposes;
  the app's worker prepares the standings once the league's `endsAt` has passed and every round is
  settled. A proposal made too early (e.g. a wrong end date) would end the season: only the admin
  can undo it, `withdrawStandings(leagueId)`, and the league then takes rounds again.
- Tie-break (off-chain, from on-chain data): points → rounds played → average lead time before the
  lock (`sumLeadTime / roundsPlayed`) → verifiable draw.

### Results and game formats

`homeScore`/`awayScore` hold the unit that decides the winner: sets in volleyball. Set by set
points stay in the attested file that `sourceHash` points to. Each game is registered with its
format, and `recordResults` checks every result against it. The format is per game, so another
head-to-head sport needs no contract change, only its format (set in the app's CMS):

| Format                             | `targetScore` | `drawAllowed` | A valid `Final`                         |
| ---------------------------------- | ------------- | ------------- | --------------------------------------- |
| Race to N (volleyball: N = 3 sets) | N             | no            | the winner has exactly N: 3-0, 3-1, 3-2 |
| Open score                         | 0             | no            | any score, the side ahead wins          |
| Open score with draws              | 0             | yes           | any score; a level score is `Draw`      |

- With a target there are no `extraPeriods` and no draws (registering both is refused).
- `extraPeriods` counts periods past regulation, for sports that have them; always 0 in volleyball.
- `Forfeit`: the winner is `Home` or `Away`, the score is 0-0 or the winner is ahead, never past
  the target.
- `Side.Draw` is 3, so it fits the 2 bits per game used for picks and outcomes.
- Not supported: a game given up by the side that leads (the forfeit check refuses it) and a level
  score decided by a shootout (a level score is only a draw).

### Roles

| Role                   | Holder                                                                       | Can                                                                                                       |
| ---------------------- | ---------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `DEFAULT_ADMIN_ROLE`   | Safe multisig, 2-of-3 (2-step transfer with delay)                           | roles, `unpause`, `setPostponeWindow`, `setCorrectionWindow`, `setFinalizationDelay`, `withdrawStandings` |
| `STEWARD_ROLE`         | Safe multisig, 2-of-3 (the app's inbox prepares the calls)                   | `pause`, `voidGame`, `correctResult`, `cancelRound`, `proposeStandings`, `finalizeLeague`                 |
| `OPERATOR_ROLE`        | worker key                                                                   | fixtures, leagues, rounds, lock updates                                                                   |
| `RESULTS_RELAYER_ROLE` | worker key                                                                   | `recordResults`                                                                                           |
| `SUBMITTER_ROLE`       | worker key                                                                   | `submitFor`, `submitForBatch`                                                                             |

Use one key per queue to avoid nonce contention. Every holder is a constructor argument: the
deploying account gets no role.

### Pause and incidents

The steward (Safe multisig, 2-of-3) pauses both contracts in minutes; only the admin (Safe
multisig, 2-of-3) unpauses. While paused every write stops except `correctResult`, `cancelRound`,
the admin functions (including `grantRole`/`revokeRole`) and the views. A pause near a lock loses
that round's late submissions: cancel it.

- **Wrong result recorded:** within `correctableUntil` of the game (the worker's inbox shows it),
  the steward calls `correctResult` with the right result. No pause is needed: the correction
  restarts the delay of every round of the game. If the relayer is at fault, the steward also
  pauses the registry to stop more writes (correcting works while paused); the admin revokes the
  faulty key if needed and unpauses.
- **Wrong result past its correction window, or a wrong correction:** before the round settles,
  the steward pauses Predictions (so nobody calls `finalizeRound` meanwhile) and cancels the
  round; the admin unpauses.
- **Worker key compromised:** the steward pauses; the admin revokes the key, grants a new one and
  unpauses. Rounds settled in the meantime are not affected; open ones may need cancelling.

## Encodings shared with the app

`scripts/lib/m2.ts` is the reference implementation of every encoding: ids, team codes, picks,
`picksHash`, EIP-712 types, `sourceHash`, scoring, standings leaves and ranking.
`test/vectors/m2-vectors.json` pins the values. Both the Solidity tests (`Vectors.t.sol`) and
the TypeScript tests check them, so the app can rely on them.

- `gameId = keccak256(bytes("mvl-2026-27-000123"))`, `leagueId = keccak256(bytes(slug))`
- `roundId = keccak256(abi.encode(leagueId, uint16 matchday))`, never reused
- team code = bytes32 short string (`bytes32("UB_BRONCOS")`)
- EIP-712 domain `("Predictions", "1", chainId, predictions)`, type
  `Submission(address user,bytes32 roundId,bytes32 picksHash,uint64 confirmedAt)`
- standings leaf (OZ `StandardMerkleTree`, `IPredictions.StandingLeaf`):
  `(bytes32 leagueId, address account, uint32 rank, uint32 points, uint32 correct, uint32 counted, uint16 roundsPlayed, uint64 sumLeadTime)`

## Commands

Requires Node ≥ 22.10 and pnpm 10.

```bash
pnpm install
pnpm build              # compile
pnpm test               # Solidity (unit, fuzz, invariants, vectors) + TypeScript (season flow, gas)
pnpm test:sol           # Solidity tests only
pnpm test:ts            # TypeScript tests only
pnpm coverage
pnpm typecheck
pnpm vectors            # regenerate test/vectors/m2-vectors.json (CI checks it is up to date)
pnpm export-abi         # ABIs, addresses, encoding lib and vectors -> ../injective-m2-frontend/packages/chain/src/generated
                        # (override the target with M2_EXPORT_DIR)
```

| Test file                         | What it covers                                                                  |
| --------------------------------- | ------------------------------------------------------------------------------- |
| `test/ResultsRegistry.t.sol`      | fixtures, rescheduling, results and formats, voids, corrections, pause, admin   |
| `test/Predictions.t.sol`          | rounds, submissions, lock moves, settlement, postponements, standings, fuzzing  |
| `test/Guards.t.sol`               | constructor, state-machine and pause guards                                     |
| `test/PredictionsInvariant.t.sol` | invariants over random submissions, moves, results, corrections and settlement  |
| `test/Vectors.t.sol`              | Solidity encodings against `test/vectors/m2-vectors.json`                       |
| `test/SeasonFlow.ts`              | a full season with viem (custodial keys, EIP-712, corrections, standings), gas  |

CI (`.github/workflows/ci.yml`) runs the build, the typecheck, the tests with coverage, the vectors
check and [Slither](https://github.com/crytic/slither) (`slither contracts --config-file
slither.config.json`, fails on medium or higher findings).

### Local node

```bash
pnpm node                       # Hardhat node, chainId 31337
pnpm deploy:localhost           # ignition/parameters/localhost.json (Hardhat default accounts)
pnpm check-deploy:localhost
```

## Deployments

| Network                        | `ResultsRegistry`                            | `Predictions`                                |
| ------------------------------ | -------------------------------------------- | -------------------------------------------- |
| Injective EVM testnet (`1439`) | `0x5E482d982f71158cBe1C811cD6086865bDF5D678` | `0xe6189297DF3B228248491c6D7AaDA78f90e09c51` |

Testnet parameters: `ignition/parameters/testnet.json` (1 h correction window and finalization
delay, no admin delay). Not deployed on mainnet yet.

## Deploy

Contracts are compiled with solc 0.8.28 (`cancun`, optimizer 200 runs); the `production` build
profile used by the deploy scripts is identical to the one the tests run against.

```bash
cp .env.example .env                                            # RPC + testnet deployer key
# admin + role holders in ignition/parameters/testnet.json (template: testnet.example.json)
pnpm deploy:testnet
pnpm check-deploy:testnet                                       # admin, roles, parameters
pnpm hardhat ignition verify chain-1439                         # Blockscout
pnpm export-abi
```

Use the **sentry** RPC endpoints. The testnet `k8s.*` endpoint returns null receipts, and Ignition
then reports deploys as dropped.

### Mainnet runbook

The admin and every role holder are constructor arguments, so the account that deploys gets no
role and only pays the gas. Anyone can deploy: us, or an account Injective authorized.

1. Ask Injective whether deployment is permissioned (EVM `authorized_deployers`): either our
   deployer gets authorized, or an authorized account deploys for us.
2. Fill `ignition/parameters/mainnet.json` from `mainnet.example.json`: admin = the admin Safe
   (2-of-3), `adminDelay` = 2 days, the worker keys, steward = the steward Safe (2-of-3).
3. Deploy from a tagged commit:
   - **we deploy:** `pnpm hardhat keystore set INJECTIVE_MAINNET_DEPLOYER_KEY`, then
     `pnpm deploy:mainnet`;
   - **a third party deploys:** they run `pnpm deploy:mainnet` from the same commit with our
     `mainnet.json` and their key, and send us the addresses, their deployer address and the
     deployment block.
4. Check it: `pnpm check-deploy:mainnet` (for a third-party deploy also set `M2_REGISTRY`,
   `M2_PREDICTIONS`, `M2_DEPLOYER`, `M2_FROM_BLOCK`). It fails if the admin, its delay, any role
   holder or parameter differs, if an admin transfer is pending, if a contract is paused, or if any
   other address (the deployer included) holds a role.
5. Verify the sources on Blockscout (`pnpm hardhat ignition verify chain-1776`, or by address if
   the journal is elsewhere): verification does not require being the deployer.
6. Fund the worker keys with INJ, run `pnpm export-abi`, commit `ignition/deployments/chain-1776`
   when we hold the journal.

Players' custodial wallets never need INJ (our relayers pay every transaction). If one ever does,
send it manually from our treasury wallet; there is no faucet.
