# injective-m2-backend

Smart contracts for M2, the free-to-play prediction game on the Mongolian basketball league, on
**Injective EVM** (chainId 1439 testnet, 1776 mainnet). Off-chain code (PWA, admin, API, worker)
lives in `injective-m2-frontend`.

| Contract | Role |
|---|---|
| `ResultsRegistry` | Per-game fixtures and results. Results come from LocalTruth attestations (CosmWasm); `sourceHash` is the attested file's SHA-256. A recorded result is final. |
| `Predictions` | Leagues, rounds (matchdays), users' signed predictions, round settlement, on-chain layer-0 scoring, final standings root (anchored once). |

## How it works

```
operator:  registerGames ─▶ createLeague ─▶ scheduleRound(leagueId, matchday, opensAt, lockTime, gameIds)
user:      "Confirm" in the app ─▶ worker signs EIP-712 Submission with the user's custodial key
submitter: submitForBatch(roundId, items)            (≤ 100 per tx, ~40k gas each; we pay the gas)
relayer:   recordResults(...)                        (after verifying the LocalTruth attestation)
             └─ final as soon as it is written: no correction, no challenge period
anyone:    finalizeRound(roundId)                    (once every game has a result: snapshots outcomes)
anyone:    scoreOf / leagueStatsOf                   (layer-0 score recomputed on-chain)
steward:   finalizeLeague(root, ...)                 (Merkle root of the final standings, write-once)
```

Key rules:

- **One submission per user per round**, immutable, accepted only while the round is open.
  `submitFor`/`submitForBatch` are restricted to `SUBMITTER_ROLE`: users never send transactions,
  and a user who exported their key cannot bypass the app's lock.
- **Picks schema 1**: one byte per game in round order, `1` home / `2` away, all games required.
  Stored packed (2 bits/game), in clear: scores are verifiable by anyone.
- `picksHash = keccak256(abi.encode(roundId, gamesHash, keccak256(picks)))` is recomputed by the
  contract; it is the receipt the app shows.
- A game counts in a round only if it was `Final`/`Forfeit` and did not tip off before the lock.
- Home/away teams are registered with the fixture; `recordResults` rejects a swapped file.
- **Results are final when recorded.** They come from an accredited institutional source (MSC,
  attested on LocalTruth), so there is no correction or challenge period: the first attested
  result of a game is the one that counts. The accepted risk is a relayer bug (e.g. a row matched
  to the wrong game) that the on-chain checks do not catch; the only remedy then is `pause`.
- A game with no result `postponeWindow` (7 days) after tip-off can be voided by the steward, so a
  round is never blocked by a game that is never played nor uploaded.
- Tie-break (off-chain, from on-chain data): points → rounds played → average lead time before the
  lock (`sumLeadTime / roundsPlayed`) → verifiable draw.

### Roles

| Role | Holder | Can |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | cold wallet (2-step transfer with delay) | roles, pause, `setPostponeWindow` |
| `STEWARD_ROLE` | a person, signing from the admin panel | `voidGame`, `cancelRound`, `finalizeLeague` |
| `OPERATOR_ROLE` | worker key | fixtures, leagues, rounds, lock updates |
| `RESULTS_RELAYER_ROLE` | worker key | `recordResults` |
| `SUBMITTER_ROLE` | worker key | `submitFor`, `submitForBatch` |

Use one key per queue to avoid nonce contention.

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
- standings leaf (OZ `StandardMerkleTree`):
  `(bytes32 leagueId, address account, uint32 rank, uint32 points, uint32 correct, uint32 counted, uint16 roundsPlayed)`

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
cp .env.example .env                                            # RPC + deployer key
cp ignition/parameters/testnet.example.json ignition/parameters/testnet.json   # role holders
pnpm deploy:testnet
pnpm hardhat ignition verify chain-1439                         # Blockscout
pnpm export-abi
```

Use the **sentry** RPC endpoints. The testnet `k8s.*` endpoint returns null receipts, and Ignition
then reports deploys as dropped.

### Mainnet runbook

1. Ask Injective to add the deployer to the EVM `authorized_deployers` param, if deployment is
   permissioned.
2. Deploy with `adminDelay` > 0 (e.g. 2 days) and the production role holders.
3. `beginDefaultAdminTransfer(coldWallet)` on each contract, then
   `acceptDefaultAdminTransfer()` from the cold wallet after the delay.
4. Fund the worker keys with INJ, run `pnpm export-abi`, commit `ignition/deployments/chain-1776`.

Players' custodial wallets never need INJ (our relayers pay every transaction). If one ever does,
send it manually from our treasury wallet; there is no faucet.
