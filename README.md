# injective-m2-backend

Smart contracts for M2, the free-to-play prediction game on real-world leagues (volleyball first;
basketball, football, tennis and other head-to-head sports with the same contracts), on
**Injective EVM** (chainId 1439 testnet, 1776 mainnet). Off-chain code (PWA, admin, API, worker)
lives in `injective-m2-frontend`.

| Contract | Role |
|---|---|
| `ResultsRegistry` | Per-game fixtures and results. Results come from LocalTruth attestations (CosmWasm); `sourceHash` is the attested file's SHA-256. A recorded result is final. |
| `Predictions` | Leagues, rounds (matchdays), users' signed predictions, round settlement, on-chain layer-0 scoring, final standings root (proposed, anchored once 48 h later). |

## How it works

```
operator:  registerGames ─▶ createLeague ─▶ scheduleRound(leagueId, matchday, opensAt, lockTime, gameIds)
user:      "Confirm" in the app ─▶ worker signs EIP-712 Submission with the user's custodial key
submitter: submitForBatch(roundId, items)            (≤ 100 per tx, ~40k gas each; we pay the gas)
relayer:   recordResults(...)                        (after the start and the LocalTruth attestation)
             └─ final as soon as it is written: no correction, no challenge period
anyone:    finalizeRound(roundId)                    (finalizationDelay, 24 h, after the round's last
                                                      result: snapshots outcomes)
anyone:    scoreOf / leagueStatsOf                   (layer-0 score recomputed on-chain)
steward:   proposeStandings(root, ...)               (Merkle root of the final standings, replaceable)
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
- A game counts in a round only if it was `Final`/`Forfeit` and did not start before the lock.
  `rescheduleGame` only accepts a future start time, so once a round is locked no move can drop one
  of its games from the score.
- Home/away teams are registered with the fixture; `recordResults` rejects a swapped file.
- **Results are final when recorded.** They come from an accredited institutional source (MSC,
  attested on LocalTruth), so there is no correction or challenge period: the first attested
  result of a game is the one that counts. No result is accepted before the start, `Void` included.
  The accepted risk is a relayer bug (e.g. a row matched to the wrong game) that the on-chain
  checks do not catch. The remedy is the finalization window: a round settles only
  `finalizationDelay` (24 h, admin-settable between 1 h and 7 days) after its last result, and
  until then the steward can cancel it (see "Pause and incidents").
- A game with no result `postponeWindow` (7 days) after its start can be voided by the steward, so a
  round is never blocked by a game that is never played nor uploaded.
- **Final standings in two steps.** The steward proposes the root once every round is settled; a
  new proposal replaces it and restarts the 48 h review. During the review `checkStanding`
  verifies any row against the proposed root and against `leagueStatsOf`, so a wrong row is
  provable on-chain. A round scheduled after the proposal makes it outdated.
- Tie-break (off-chain, from on-chain data): points → rounds played → average lead time before the
  lock (`sumLeadTime / roundsPlayed`) → verifiable draw.

### Sports and results

The contracts are sport-agnostic. `homeScore`/`awayScore` hold the unit that decides the winner;
partial scores (set by set, periods) stay in the attested file that `sourceHash` points to. Each
game is registered with its format, and `recordResults` checks every result against it:

| Sport | Score | `targetScore` | `drawAllowed` | A valid `Final` |
|---|---|---|---|---|
| Volleyball (best of 5) | sets | 3 | no | 3-0, 3-1, 3-2 |
| Beach volleyball (best of 3) | sets | 2 | no | 2-0, 2-1 |
| Tennis | sets | 2 or 3 | no | the winner reached the target |
| Basketball | points | 0 | no | any score, no tie |
| Football (league) | goals | 0 | yes | any score; a level score is `Draw` |

- `targetScore` 0 means an open score: the winner is the side ahead. With `targetScore` N the
  winner has exactly N and there are no `extraPeriods`; draws cannot be allowed with a target.
- `extraPeriods` counts periods past regulation (basketball overtimes, football extra time).
- `Forfeit`: the winner is `Home` or `Away`, the score is 0-0 or the winner is ahead, never past
  the target.
- `Side.Draw` is 3, so it fits the 2 bits per game used for picks and outcomes.
- Not supported yet: a tennis retirement where the retiring player leads, and a knockout football
  match decided on penalties (level score with a winner).

### Roles

| Role | Holder | Can |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | cold wallet (2-step transfer with delay) | roles, `unpause`, `setPostponeWindow`, `setFinalizationDelay` |
| `STEWARD_ROLE` | a person, signing from the admin panel | `pause`, `voidGame`, `cancelRound`, `proposeStandings`, `finalizeLeague` |
| `OPERATOR_ROLE` | worker key | fixtures, leagues, rounds, lock updates |
| `RESULTS_RELAYER_ROLE` | worker key | `recordResults` |
| `SUBMITTER_ROLE` | worker key | `submitFor`, `submitForBatch` |

Use one key per queue to avoid nonce contention. Every holder is a constructor argument: the
deploying account gets no role.

### Pause and incidents

The steward pauses both contracts from the admin panel in minutes; only the admin (cold wallet)
unpauses. While paused every write stops except `cancelRound`, the admin functions (including
`grantRole`/`revokeRole`) and the views. A pause near a lock loses that round's late submissions:
cancel it.

- **Wrong result recorded:** within `finalizationDelay` of the round's last result, the steward
  pauses (to stop more writes if the relayer is at fault) and cancels the round. The admin then
  revokes the faulty key if needed and unpauses.
- **Worker key compromised:** the steward pauses; the admin revokes the key, grants a new one and
  unpauses. Rounds settled in the meantime are not affected; open ones may need cancelling.

## Encodings shared with the app

`scripts/lib/m2.ts` is the reference implementation of every encoding: ids, team codes, picks,
`picksHash`, EIP-712 types, `sourceHash`, scoring, standings leaves and ranking.
`test/vectors/m2-vectors.json` pins the values. Both the Solidity tests (`Vectors.t.sol`) and
the TypeScript tests check them, so the app can rely on them.

- `gameId = keccak256(bytes("mbl-2026-27-000123"))`, `leagueId = keccak256(bytes(slug))`
- `roundId = keccak256(abi.encode(leagueId, uint16 matchday))`, never reused
- team code = bytes32 short string (`bytes32("UB_BRONCOS")`)
- EIP-712 domain `("M2Predictions", "1", chainId, predictions)`, type
  `Submission(address user,bytes32 roundId,bytes32 picksHash,uint64 confirmedAt)`
- standings leaf (OZ `StandardMerkleTree`, `IPredictions.StandingLeaf`):
  `(bytes32 leagueId, address account, uint32 rank, uint32 points, uint32 correct, uint32 counted, uint16 roundsPlayed, uint64 sumLeadTime)`

## Commands

Requires Node ≥ 22.10 and pnpm 10.

```bash
pnpm install
pnpm build              # compile
pnpm test               # Solidity (unit, fuzz, invariants, vectors) + TypeScript (season flow, gas)
pnpm coverage
pnpm typecheck
pnpm vectors            # regenerate test/vectors/m2-vectors.json (CI checks it is up to date)
pnpm export-abi         # ABIs, addresses, encoding lib and vectors -> ../injective-m2-frontend/packages/chain/src/generated
```

## Deploy

```bash
cp .env.example .env                                            # RPC + testnet deployer key
cp ignition/parameters/testnet.example.json ignition/parameters/testnet.json   # admin + role holders
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
2. Fill `ignition/parameters/mainnet.json` from `mainnet.example.json`: admin = cold wallet,
   `adminDelay` = 2 days, the worker keys, the steward wallet.
3. Deploy from a tagged commit:
   - **we deploy:** `pnpm hardhat keystore set INJECTIVE_MAINNET_DEPLOYER_KEY`, then
     `pnpm deploy:mainnet`;
   - **a third party deploys:** they run `pnpm deploy:mainnet` from the same commit with our
     `mainnet.json` and their key, and send us the addresses, their deployer address and the
     deployment block.
4. Check it: `pnpm check-deploy:mainnet` (for a third-party deploy also set `M2_REGISTRY`,
   `M2_PREDICTIONS`, `M2_DEPLOYER`, `M2_FROM_BLOCK`). It fails if the admin, its delay, any role
   holder or parameter differs, or if any other address (the deployer included) holds a role.
5. Verify the sources on Blockscout (`pnpm hardhat ignition verify chain-1776`, or by address if
   the journal is elsewhere): verification does not require being the deployer.
6. Fund the worker keys with INJ, run `pnpm export-abi`, commit `ignition/deployments/chain-1776`
   when we hold the journal.

Players' custodial wallets never need INJ (our relayers pay every transaction). If one ever does,
send it manually from our treasury wallet; there is no faucet.
