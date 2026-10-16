# Handoff: adapt the worker to result corrections, the standings lock and postponements

For: an agent working in `injective-m2-frontend` (sibling of this repo). Do the steps in order.
The contracts, tests, deploy files and README are already done in `injective-m2-backend`. Read the
"How it works", "Key rules" and "Pause and incidents" sections of its README first.

Ship the worker changes together with the new contracts: step 5 fixes a job that would otherwise
fail on every pass once the start-time rule is live, and step 1 renames a view the worker calls.

## What changed on-chain

### ResultsRegistry

- **New steward function** `correctResult(ResultInput r, string reason)`:
  - replaces a game's result (or void) **once**, before `correctableUntil(gameId)`;
  - runs the same checks as `recordResults` (teams, format, non-zero `sourceHash`, attestation id
    of 1–128 bytes);
  - the source may be the same attested file (parser bug) or a new one;
  - sets `recordedAt = now`, `corrected = true` and `correctableUntil = 0`;
  - **works while paused**.
- **Reverts** of `correctResult`:
  - `NoResult(gameId)`;
  - `AlreadyCorrected(gameId)`;
  - `CorrectionWindowClosed(gameId, correctableUntil)`;
  - plus the record errors (`TeamsMismatch`, `InvalidResult`, `InvalidSource`).
- **Event** `ResultCorrected(gameId, status, winner, homeScore, awayScore, extraPeriods, sourceHash, attestationId, reason)`.
- **View** `correctableUntil(bytes32 gameId) returns (uint64)`. It is 0 when the game has no result
  or was corrected. Otherwise it equals `recordedAt + correctionWindow`, fixed when the result is
  written, so changing the window later never reopens it. After it has passed it keeps that past
  value: compare it with the chain time.
- **`Game` struct** gains two fields: `uint64 correctableUntil` and `bool corrected`. `getGame`
  returns them. `outcomeOf` is unchanged.
- `voidGame` (steward) also sets `correctableUntil`: the steward can turn their own void into a
  result once, within the window.
- **Admin**: `correctionWindow` (default 24 h, range 1 h – 7 days), `setCorrectionWindow`, event
  `CorrectionWindowSet`.
- **Constructor**: new 4th argument `initialCorrectionWindow`. The Ignition parameter is
  `correctionWindow`. The frontend does not deploy contracts itself (it reads the Ignition
  journals), so this only matters if you add a deploy script.
- **`isFinal` is renamed `hasResult`** (same meaning: the game has a result, which may still be
  corrected once).
- **`registerGames` reverts `StartTimeInPast(gameId, startTime)`** for a start time that is not in
  the future, as `rescheduleGame` does. A single such game reverts the whole batch.

### Predictions

- `finalizableAt` / `finalizeRound` now wait for
  `max(recordedAt + finalizationDelay, correctableUntil)` over the round's games.
  - A correction moves `finalizableAt` forward (new `recordedAt` + delay).
  - A settled round can never see one of its results change afterwards.
- The error `GameNotFinal(gameId)` is renamed `NoResult(gameId)` (a game of the round has no
  result yet).
- `scheduleRound` reverts `StandingsAlreadyProposed(leagueId)` while the league has a standings
  proposal, even after it was replaced: **proposing the standings ends the season**.
- **New admin function** `withdrawStandings(leagueId)`, event `StandingsWithdrawn(leagueId)`: the
  cold wallet undoes a proposal made too early. `getStandingsProposal` then returns
  `proposedAt = 0`, the league takes rounds again, and the steward proposes once it is over.
  Reverts `NoStandingsProposal`, `LeagueNotActive` (finalized league). Works while paused.
- The `StandingsOutdated` check in `finalizeLeague` is now unreachable; it is kept as a guard.

### ResultsRegistry: a start time freezes at the start

- `rescheduleGame` now reverts `GameAlreadyStarted(gameId, startTime)` once
  `block.timestamp >= startTime`.
  - That is the same instant from which `recordResults` accepts a result. Before the start a
    game can move and takes no result; from the start on, its start time is fixed and it only
    takes a result or a void.
  - Why: a game brought forward before a round's lock and played could be moved back after the
    lock and count again, rewarding picks confirmed once its result was known.
- **Postponement known before the start:** unchanged, `rescheduleGame` to the new date.
- **Postponement known after the start** (the game did not take place at its date):
  - the on-chain start time stays;
  - the replay's result is recorded on the **same game id** and counts in the round, with the
    same score as if the date had moved;
  - nothing on-chain refuses an early result for that game any more (before, moving the date
    restored the `BeforeStart` guard). A `void` recorded before the replay becomes final once
    `correctableUntil` passes: the replay can then no longer be recorded
    (`ResultAlreadyRecorded`, `CorrectionWindowClosed`). The worker is the only guard (step 7).
- **`voidGame`** is allowed once the original start + `postponeWindow` (default 7 days) has
  passed. It is a minimum, not a deadline: until the steward voids the game, a late replay is
  still recorded and counts. The round waits for it (`finalizableAt` stays 0).
- **A started game cannot join a later round:** `scheduleRound` reverts `LockAfterStart`. A
  replay meant to count in a later round needs a new game (new `canonicalGameId`), and the old one
  must end as a void.
- **Corner case:** a game brought forward whose anticipation is undone only after the anticipated
  time stays out of its round, and `updateRoundLock` on that round reverts `LockAfterStart`.

## Inbox kinds

Add these to `kind` in `packages/cms/src/collections/ops.ts` (a value not listed fails Payload's
validation), then regenerate `payload-types.ts`:

| Kind | Opened by |
|---|---|
| `result_corrected` | step 3: a result changed on-chain after it was first recorded |
| `standings_locked` | step 4: a round of a league whose standings are proposed |
| `game_postponed` | steps 5–7: a started game moved in the CMS, a held-back void or row |
| `void_due` | step 8: a game past `startTime + postponeWindow` with no result |

## Steps

### 1. Regenerate the ABIs and redeploy locally

From `injective-m2-backend`, run `pnpm export-abi`. It writes `packages/chain/src/generated/abis.ts`
(and addresses, encodings, vectors). For the e2e test, also restart the Hardhat node and run
`pnpm deploy:localhost`: the constructor changed and the test reads `chain-31337`. Then run the
frontend typecheck and fix what breaks:

- `isFinal` no longer exists (`hasResult`); step 3 replaces its only call in `settle.ts`.
- `getGame` results now carry `correctableUntil` (a `bigint`, like `startTime` and `recordedAt`)
  and `corrected`.

### 2. `apps/worker/src/jobs/results.ts`: conflicts

- **Header comment**: it says "A recorded result is final: a different result arriving later for
  the same game is only reported (result_conflict), never written". Update it: the result is
  reported, and the steward may correct it once within `correctableUntil`.
- **`sameResult` misses conflicts.** It compares only status and scores, so a 0-0 forfeit where
  the other team forfeits, or a different `extraPeriods`, counts as the same result and is skipped
  silently. Compare the whole `toResultInput` of the row with the on-chain game: `status`,
  `winner`, `homeScore`, `awayScore`, `extraPeriods`.
- **`result_conflict` inbox item** (around the `sameResult` check). Read
  `registry.correctableUntil(gameId)` and `chainNow(ctx)`.
  - **If the window is open** (`now < correctableUntil`):
    - title: "…reports a different result; check it with the official source, and if it is the
      right one correct it before <ISO date>". The proposal comes from an attested file: the
      steward must not sign it blindly;
    - add a `sign` block, following `standings_ready` in `jobs/league.ts`:
      `sign: { contract: ctx.chain.contracts.registry, function: 'correctResult', args: [input, '<reason>'], data }`,
      where `data` is `encodeFunctionData` of the same call: the `ResultInput` tuple is awkward to
      type into a wallet, raw calldata is not. Add `data` to the other `sign` blocks too;
    - put the recorded and the reported result side by side in the payload, plus
      `correctableUntil` (ISO).
  - **If the window is closed** (this includes a game already corrected, whose `correctableUntil`
    reads 0): keep the current text, and add that the remedy is cancelling the affected rounds
    before they settle.
  - Use `jsonSafe` as today for bigints.
- **Note on `sign`**: nothing in `apps/web` renders `sign` yet; the steward signs from their own
  wallet. Keep it informational, exactly like `proposeStandings`.
- **Validate before proposing a correction**: run `validateResult(input, { targetScore, drawAllowed })`
  first, with the on-chain format, as the record path does. Never propose a correction the
  registry would refuse.

### 3. `apps/worker/src/jobs/settle.ts` (`finalizeRounds` / `openReview`)

- **Sync every changed result, not only full rounds.** In `finalizeRounds`, replace the `isFinal`
  calls with `getGame` (it gives `recordedAt`, `correctableUntil` and `corrected` too). For every
  game of a locked round whose on-chain `recordedAt` differs from the DB `recordedAt`, call
  `syncGameResult(ctx, game)`, before the "all results in" check. Otherwise a correction, or a
  steward `voidGame`, stays invisible in the app while another game of the round still waits for
  its result. `mirrorRound` already re-syncs every game at settlement; this covers the time before.
- **Alert on every correction.** A correction is a new power of the steward's hot wallet: the
  team must see each one while there is time to react (the round waits `finalizationDelay` after
  it, so the admin can revoke the key and the rounds can be cancelled). When the sync finds a game
  whose DB already had a result and whose on-chain `recordedAt` changed, open a `result_corrected`
  item (severity `warning`, dedupe `corrected:${g.id}:${recordedAt}`) with the old and the new
  result and the `reason`, read from the `ResultCorrected` log
  (`getContractEvents`, `eventName: 'ResultCorrected'`, `args: { gameId }`).
- Add a `corrected` checkbox to the `games` collection
  (`packages/cms/src/collections/competition.ts`, next to `chainField('recordedAt', 'date')`),
  filled by `syncGameResult` from `g.corrected`. Then regenerate `payload-types.ts`.
- **`round_review` item.**
  - Build its payload from the synced values: `games` is loaded with the round before the sync,
    so re-read the games (or use the `getGame` results).
  - Its `dedupeKey` is `round-review:${round.id}`, so it opens only once. After a correction the
    deadline moves: use `round-review:${round.id}:${readyAt}` so the steward gets a fresh item with
    the new deadline. Optionally resolve the previous one.
  - Add each game's `correctableUntil` (ISO, or null) to `payload.results`.
  - Replace `ifWrong`. New text: "Before the game's correctableUntil, from the steward wallet:
    ResultsRegistry.correctResult(rightResult, reason); no pause needed. After it, or if the
    correction is wrong too: pause Predictions, then Predictions.cancelRound(roundId, reason)
    before finalizableAt; the admin unpauses."
- **Detection.** A parser bug re-reads the same file, so it never produces a `result_conflict`;
  only the steward's review of `round_review` catches it. Make the item title say "check the
  results; a wrong one can be corrected until <earliest correctableUntil>".
- **`missing_result`**: skip it for a game marked `postponed` (step 6); step 8 covers those.

### 4. `apps/worker/src/jobs/sync.ts` (`registerGames`, `scheduleRounds`) and the CMS

- **`registerGames`**: before building the batch, leave out every game whose CMS `startTime` is
  not in the future (chain time) and open a `chain_error` item for it: one such game would revert
  the whole `registerGames` batch (`StartTimeInPast`). The CMS should also refuse marking a round
  `ready` with a game whose start has passed.
- **Standings proposed.** Before sending `scheduleRound`, check
  `predictions.read.getStandingsProposal([leagueId])`. If `proposedAt != 0n`, do not send it.
  Open a `standings_locked` item instead (severity `warning`, dedupe on the round id): the league's
  standings are proposed, so the round cannot be added; only the admin can withdraw the proposal
  (`withdrawStandings`).
- In the rounds collection (`packages/cms/src/collections/competition.ts`, the `beforeChange`
  validation next to "lockTime must not be after the first start time"), refuse creating a round,
  or marking one `ready`, for a league whose `standingsProposedAt` is set. This is required, not
  optional: the proposal is what ends the season.
- **Start times.** Before sending `scheduleRound`, check every game's **on-chain** `startTime`
  against the round's `lockTime`: `startTime < lockTime` reverts `LockAfterStart`. Open an inbox
  item instead of sending, with the remedy that fits the cause:
  - the start has passed: the game can never join a round, so a replay must be registered as a
    new game;
  - the start is still ahead (the game was moved earlier while the round was `ready`): move the
    round's lock in the CMS to the game's start or earlier.

### 5. `apps/worker/src/jobs/sync.ts` (`syncChanges`): start time changes after the start

Today the pre-check compares the **new** CMS date with now. With the new rule, a date changed in
the CMS after the on-chain start passes makes `rescheduleGame` revert in the simulation:
`sendContractTx` throws, the loop has no try/catch, `startTimeNeedsSync` is never reset, and the
job fails on every pass without reaching the lock moves (`updateRoundLock`) further down.

- In the games loop, before sending, add: if `now >= onchain.startTime` (and the game is still
  `Scheduled` on-chain), do **not** send. Instead:
  - open a `game_postponed` item, dedupe `reschedule-started:${g.id}`, saying: "the game has
    started on-chain, its start time stays; the replay's result will be recorded on the same
    game; the steward may void it from <onchain.startTime + postponeWindow>";
  - mark the game as postponed (step 6);
  - reset `startTimeNeedsSync` as for the other branches.
- Keep the CMS date as the editor set it: the app shows it and result matching by date uses it
  (`matchRow` compares the row's Ulaanbaatar date with the DB `startTime`). Only the on-chain
  start stays put.
- Read `postponeWindow` from `registry.read.postponeWindow()`, not from a constant.

### 6. CMS: mark postponed games

The CMS has no way to say a game did not take place at its date and awaits a replay. Add it.

- In the `games` collection (`packages/cms/src/collections/competition.ts`), add a `postponed`
  checkbox. The editor ticks it when the postponement is announced; the new date, if known, goes
  in `startTime` as usual. "Postponed, date to be announced" is just the checkbox.
- Safety net: the worker also treats as postponed a game that is `Scheduled` on-chain, whose
  on-chain start has passed, and whose CMS `startTime` is later than the on-chain one. If the
  checkbox is not ticked in that case, open a `game_postponed` item asking the editor to confirm
  the postponement.
- Clear the flag when the game gets a result (`syncGameResult`).
- Show it in the app (results page and pick board): "postponed", plus the new date when known,
  instead of the original date. Add the label to `packages/i18n` in both `en` and `mn`
  (`apps/web/test/i18n-keys.test.ts` checks both).
- Regenerate `payload-types.ts`.

### 7. `apps/worker/src/jobs/results.ts`: postponed games and held-back voids

Nothing on-chain refuses an early result for a game postponed after its start, so the worker
is the only guard.

- In `processAttestations`, for a game that is postponed (step 6) and `Scheduled` on-chain:
  - a `void` row: do **not** record it. Open a `game_postponed` item (severity `warning`) for the
    steward: is the game cancelled for good (then untick `postponed` and set the attestation back to
    `new`, see below, so the void is recorded; or `voidGame` once the window allows), or only postponed (then ignore the row)? Recording it
    would make the replay unrecordable once `correctableUntil` passes;
  - a `final` or `forfeit` row whose date is the original start, not the replay's: same, inbox
    instead of recording;
  - a `final` or `forfeit` row for the replay: record it as usual, on the same game.
- **Hold back every void for a while, not only on postponed games.** MSC's file may report the
  game as `void` before the editor ticks `postponed` (attestations are processed every 2
  minutes). Record a `void` row only once the chain time is past the attestation's `createdAt`
  plus a hold (a constant, 12 h); until then keep the attestation in `retry` with `retryAfter` at
  that time, and open a `game_postponed` item: "MSC reports <game> as void: it is recorded at
  <time> unless the game is marked postponed". A void counts for no one, so the delay is harmless;
  after recording, `correctResult` still gives the steward `correctionWindow`.
- **Re-process attestations.** `needs_review` is final today and `attestations` has
  `update: nobody`, so a row reported as `unmatched_row` is never retried, even after the editor
  fixes the game (a replay's new MSC `game_id` in `externalGameId`, or its date). Let staff set an
  attestation's `status` back to `new` from the admin (update access for `operator` and
  `steward`, every other field read-only). Re-processing is safe: rows already recorded are
  skipped by `sameResult`.
- Ask MSC how a postponed game appears in their files (left out, `void`, or a new `game_id` for
  the replay), and note the answer in `packages/results/src/spec.ts`. If the replay gets a new
  MSC `game_id`, update `externalGameId` on the game, otherwise `matchRow` reports
  `unmatched_row`.
- Update the header comment: no result is written before the start, but a game postponed after
  its start keeps its start time, so the worker holds back voids and early rows for it.

### 8. Void reminder

Nothing reminds the steward that a postponed game can be voided, so its round stays unsettled.
That also freezes the app's leaderboard for every later matchday (`scoreRounds` scores rounds in
matchday order) and, at the end of the season, blocks `proposeStandings`. The steward's choice
between voiding and waiting for the replay has that cost: say it in the item.

- Add a check (in `settle.ts`, or a small job of its own): for every game of a locked, unsettled
  round that is `Scheduled` on-chain and whose `onchain.startTime + postponeWindow` has passed,
  open a `void_due` item, dedupe `voidable:${g.id}`, with a `sign` block in the same shape as
  `standings_ready`:
  `sign: { contract: ctx.chain.contracts.registry, function: 'voidGame', args: [gameIdHash, '<reason>'], data }`.
- Title: "<game> was not replayed within postponeWindow: void it if it will not be played, or
  wait for the replay's result (its round and the leaderboard wait too)". The decision stays with
  the steward: until the void, a late replay still counts.

### 9. `apps/worker/src/jobs/league.ts`: the standings end the season

- **`standings_ready`**: the title must say that proposing ends the season: no round can be added
  afterwards, and only the admin can withdraw the proposal. A wrong `endsAt` in the CMS is enough
  to have the worker prepare standings mid-season, once the rounds created so far are settled.
- **`syncStandingsProposals`**: the branch `proposal.roundCount !== onchain.roundCount` is now
  unreachable. Turn it into a `critical` `chain_error` ("invariant broken, do not finalize").
- **Withdrawn proposal.** After `withdrawStandings`, `getStandingsProposal` returns
  `proposedAt = 0` while the DB still has `standingsRoot`, so today the league is skipped by both
  `syncStandingsProposals` and `prepareStandings` forever. When the DB has `standingsProposedAt`
  set and the chain has no proposal, call `clearStandings`, so the standings are prepared again
  once the season is really over, and open a `standings_locked` item (severity `info`) saying the
  league takes rounds again.

### 10. Robustness: one revert must not stop a job

The `sync` job runs `registerGames → createLeagues → scheduleRounds → syncChanges` in sequence
(`apps/worker/src/main.ts`), and the loops have no try/catch per item: any revert in the
simulation stops every later step, lock moves included. The pre-checks of steps 4 and 5 cover the
new reverts, but not the ones nobody foresaw, nor `EnforcedPause` while the steward has paused a
contract. Wrap each item of these loops (and of `finalizeRounds`, where a correction landing
between `finalizableAt` and the transaction makes `finalizeRound` revert `FinalizationPending`) in
a try/catch that opens a `chain_error` item, dedupe on the item and the error name, and goes on
with the next one.

### 11. Docs

- Frontend `README.md`, around line 50 ("A recorded result is final … only opens a
  `result_conflict` item"). Update it: the steward can correct a result once, within
  `correctableUntil`, and the inbox gives the ready-made call. Also line 53: if a result is wrong,
  the steward corrects it; cancelling the round is the last resort.
- Add the postponement procedure: before the start, move the date; after it, tick `postponed`
  and set the new date when known; the replay counts on the same game; void after
  `postponeWindow` only if it will not be played; a replay meant for a later round is a new game.
- Add that proposing the standings ends the season, and that only the admin can undo it
  (`withdrawStandings`).
- Any steward runbook in the frontend repo: same incident procedure as the backend README's
  "Pause and incidents".

### 12. Tests

`apps/worker/test/e2e.test.ts` uses the contracts deployed on the local node (step 1). Add:

- **A correction during the review**:
  1. record a result;
  2. as the steward, call `correctResult`;
  3. run `finalizeRounds` and check that the DB game shows the corrected score before
     settlement, that a `result_corrected` item is open, that `round.finalizableAt` moved, and
     that the round settles on the corrected outcome.
- **A `result_conflict` with the window open**: the item has the `sign.correctResult` payload,
  and `data` decodes to the same call.
- **A conflicting 0-0 forfeit** (the other team forfeits): it opens a `result_conflict`.
- **`scheduleRounds` after `proposeStandings`**: no transaction is sent and a `standings_locked`
  item is opened; after `withdrawStandings` (admin) the round is scheduled and the DB standings
  are cleared.
- **A game with a past start time in a `ready` round**: `registerGames` registers the other games
  and opens an item for it.
- **A date moved in the CMS after the on-chain start**: `syncChanges` sends nothing, opens the
  inbox item, resets `startTimeNeedsSync`, and still syncs a lock move queued in the same pass.
- **A postponed game**: a `void` row for it opens an inbox item and records nothing; the
  replay's `final` row is recorded on the same game and the round settles with it counting.
- **A void on a game not marked postponed**: it is recorded only after the hold.
- **The void reminder**: past `startTime + postponeWindow` a `Scheduled` game opens one
  `void_due` item with the `sign.voidGame` payload.
- **A round with a started game**: `scheduleRounds` sends nothing and opens an inbox item.

## Do not

- Do not let the worker call `correctResult`. The worker keys do not hold `STEWARD_ROLE`, and the
  decision is the steward's.
- Do not change how results are recorded: the relayer still writes only the first attested result
  of a game (after the void hold of step 7).
- Do not let the worker call `voidGame` either: it is a steward decision, the reminder only
  prepares the call.
- Do not try to move a started game on-chain by any other route (a new round, a lock move): its
  start time is fixed by design.
