# Handoff: adapt the worker to result corrections, the standings lock and postponements

For: an agent working in `injective-m2-frontend` (sibling of this repo). Do the steps in order.
The contracts, tests, deploy files and README are already done in `injective-m2-backend`. Read the
"How it works", "Key rules" and "Pause and incidents" sections of its README first.

Ship the worker changes together with the new contracts: step 5 fixes a job that would otherwise
fail on every pass once the start-time rule is live.

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
  written, so changing the window later never reopens it.
- **`Game` struct** gains two fields: `uint48 correctableUntil` and `bool corrected`. `getGame`
  returns them. `outcomeOf` is unchanged.
- **Admin**: `correctionWindow` (default 24 h, range 1 h – 7 days), `setCorrectionWindow`, event
  `CorrectionWindowSet`.
- **Constructor**: new 4th argument `initialCorrectionWindow`. The Ignition parameter is
  `correctionWindow`. The frontend does not deploy contracts itself (it reads the Ignition
  journals), so this only matters if you add a deploy script.
- **`isFinal(gameId)`** is unchanged: it means "has a result", which may still be corrected once.

### Predictions

- `finalizableAt` / `finalizeRound` now wait for
  `max(recordedAt + finalizationDelay, correctableUntil)` over the round's games.
  - A correction moves `finalizableAt` forward (new `recordedAt` + delay).
  - A settled round can never see one of its results change afterwards.
- `scheduleRound` reverts `StandingsAlreadyProposed(leagueId)` once `proposeStandings` has been
  called for the league, even after the proposal was replaced.
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
  - nothing on-chain refuses an early result for that game any more. A `void` recorded before
    the replay becomes final once `correctableUntil` passes: the replay can then no longer be
    recorded (`ResultAlreadyRecorded`, `CorrectionWindowClosed`).
- **`voidGame`** is allowed from the original start + `postponeWindow` (default 7 days). It is a
  minimum, not a deadline: until the steward voids the game, a late replay is still recorded and
  counts. The round waits for it (`finalizableAt` stays 0).
- **A started game cannot join a later round:** `scheduleRound` reverts `LockAfterStart`. A
  replay meant to count in a later round needs a new game (new `canonicalGameId`), and the old one
  must end as a void.
- **Corner case:** a game brought forward whose anticipation is undone only after the anticipated
  time stays out of its round, and `updateRoundLock` on that round reverts `LockAfterStart`.
- The ABI gains the error `GameAlreadyStarted`. Nothing else changes: `getGame`, `outcomeOf`,
  events and Predictions are as before.

## Steps

### 1. Regenerate the ABIs

From `injective-m2-backend`, run `pnpm export-abi`. It writes `packages/chain/src/generated/abis.ts`
(and addresses, encodings, vectors). Then run the frontend typecheck and fix what breaks: `getGame`
results now carry `correctableUntil` and `corrected`.

### 2. `apps/worker/src/jobs/results.ts`

- **Header comment**: it says "A recorded result is final: a different result arriving later for
  the same game is only reported (result_conflict), never written". Update it: the result is
  reported, and the steward may correct it once within `correctableUntil`.
- **`result_conflict` inbox item** (around the `sameResult` check). Read
  `registry.correctableUntil(gameId)` and `chainNow(ctx)`.
  - **If the window is open** (`now < correctableUntil`):
    - title: "…reports a different result; correct it before <ISO date> if it is the right one";
    - add a `sign` block, following `standings_ready` in `jobs/league.ts`:
      `sign: { contract: ctx.chain.contracts.registry, function: 'correctResult', args: [input, '<reason>'] }`;
    - also put `correctableUntil` (ISO) in the payload.
  - **If the window is closed**: keep the current text, and add that the remedy is cancelling the
    affected rounds before they settle.
  - Use `jsonSafe` as today for bigints.
- **Note on `sign`**: nothing in `apps/web` renders `sign` yet; the steward signs from their own
  wallet. Keep it informational, exactly like `proposeStandings`.
- **Validate before proposing a correction**: run `validateResult(input, { targetScore, drawAllowed })`
  first, as the record path does. Never propose a correction the registry would refuse.

### 3. `apps/worker/src/jobs/settle.ts` (`finalizeRounds` / `openReview`)

- **Sync corrected results.** A corrected result must show in the app before the round settles.
  For a locked round whose games are all final, call `syncGameResult(ctx, game)` for each game
  whose on-chain `recordedAt` differs from the DB `recordedAt`. Do this before `openReview`.
  `mirrorRound` already re-syncs every game at settlement, so this only covers the window before it.
  - Also consider adding a `corrected` checkbox to the `games` collection
    (`packages/cms/src/collections/competition.ts`, next to `chainField('recordedAt', 'date')`),
    filled by `syncGameResult` from `g.corrected`. Then regenerate `payload-types.ts`.
- **`round_review` item.**
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

### 4. `apps/worker/src/jobs/sync.ts` (`scheduleRounds`) and the CMS

- Before sending `scheduleRound`, check `predictions.read.getStandingsProposal([leagueId])`. If
  `proposedAt != 0`, do not send it. Open an inbox item instead (kind `lock_risk` or a new
  `standings_locked` kind added to `packages/cms/src/collections/ops.ts`), severity `warning`,
  dedupe on the round id, saying the league's standings are already proposed so the round cannot
  be added.
- Optional: in the rounds collection (`packages/cms/src/collections/competition.ts`, the
  `beforeChange` validation next to "lockTime must not be after the first start time"), refuse
  creating a round for a league whose `standingsProposedAt` is set.
- Before sending `scheduleRound`, also check every game's **on-chain** `startTime` against the
  round's `lockTime`: a game whose start has passed can never join a round (`LockAfterStart`).
  Open an inbox item instead of sending, saying a replay must be registered as a new game.

### 5. `apps/worker/src/jobs/sync.ts` (`syncChanges`): start time changes after the start

Today the pre-check compares the **new** CMS date with now. With the new rule, a date changed in
the CMS after the on-chain start passes makes `rescheduleGame` revert in the simulation:
`sendContractTx` throws, the loop has no try/catch, `startTimeNeedsSync` is never reset, and the
job fails on every pass without reaching the lock moves (`updateRoundLock`) further down.

- In the games loop, before sending, add: if `now >= onchain.startTime` (and the game is still
  `Scheduled` on-chain), do **not** send. Instead:
  - open an inbox item (kind `chain_error`, or a new `game_postponed` kind in
    `packages/cms/src/collections/ops.ts`), dedupe `reschedule-started:${g.id}`, saying: "the game
    has started on-chain, its start time stays; the replay's result will be recorded on the same
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
  checkbox is not ticked in that case, open an inbox item asking the editor to confirm the
  postponement.
- Clear the flag when the game gets a result (`syncGameResult`).
- Show it in the app: "postponed", plus the new date when known, instead of the original date.
- Regenerate `payload-types.ts`.

### 7. `apps/worker/src/jobs/results.ts`: postponed games

Nothing on-chain refuses an early result for a game postponed after its start, so the worker
is the only guard.

- In `processAttestations`, for a game that is postponed (step 6) and `Scheduled` on-chain:
  - a `void` row: do **not** record it. Open an inbox item (severity `warning`) for the steward:
    is the game cancelled for good (then record the void, or `voidGame` once the window allows),
    or only postponed (then ignore the row)? Recording it would make the replay unrecordable once
    `correctableUntil` passes;
  - a `final` or `forfeit` row whose date is the original start, not the replay's: same, inbox
    instead of recording;
  - a `final` or `forfeit` row for the replay: record it as usual, on the same game.
- Ask MSC how a postponed game appears in their files (left out, `void`, or a new `game_id` for
  the replay), and note the answer in `packages/results/src/spec.ts`. If the replay gets a new
  MSC `game_id`, update `externalGameId` on the game, otherwise `matchRow` reports
  `unmatched_row`.
- Update the header comment: no result is written before the start, but a game postponed after
  its start keeps its start time, so the worker must hold back a void for it.

### 8. Void reminder

Nothing reminds the steward that a postponed game can be voided, so its round stays unsettled
(and, at the end of the season, blocks `proposeStandings`).

- Add a check (in `settle.ts`, or a small job of its own): for every game `Scheduled` on-chain
  whose `onchain.startTime + postponeWindow` has passed, open an inbox item, dedupe
  `voidable:${g.id}`, with a `sign` block in the same shape as `standings_ready`:
  `sign: { contract: ctx.chain.contracts.registry, function: 'voidGame', args: [gameIdHash, '<reason>'] }`.
- Title: "<game> was not replayed within postponeWindow: void it if it will not be played, or
  wait for the replay's result". The decision stays with the steward: until the void, a late
  replay still counts.

### 9. Docs

- Frontend `README.md`, around line 52 ("A recorded result is final … only opens a
  `result_conflict` item"). Update it: the steward can correct a result once, within
  `correctableUntil`, and the inbox gives the ready-made call.
- Add the postponement procedure: before the start, move the date; after it, tick `postponed`
  and set the new date when known; the replay counts on the same game; void after
  `postponeWindow` only if it will not be played; a replay meant for a later round is a new game.
- Any steward runbook in the frontend repo: same incident procedure as the backend README's
  "Pause and incidents".

### 10. Tests

`apps/worker/test/e2e.test.ts` deploys the contracts with the backend's Ignition module, so
re-export first. Add:

- **A correction during the review**:
  1. record a result;
  2. as the steward, call `correctResult`;
  3. run `finalizeRounds` and check that the DB game shows the corrected score before
     settlement, that `round.finalizableAt` moved, and that the round settles on the corrected
     outcome.
- **A `result_conflict` with the window open**: the item has the `sign.correctResult` payload.
- **`scheduleRounds` after `proposeStandings`**: no transaction is sent and an inbox item is
  opened.
- **A date moved in the CMS after the on-chain start**: `syncChanges` sends nothing, opens the
  inbox item, resets `startTimeNeedsSync`, and still syncs a lock move queued in the same pass.
- **A postponed game**: a `void` row for it opens an inbox item and records nothing; the
  replay's `final` row is recorded on the same game and the round settles with it counting.
- **The void reminder**: past `startTime + postponeWindow` a `Scheduled` game opens one item
  with the `sign.voidGame` payload.
- **A round with a started game**: `scheduleRounds` sends nothing and opens an inbox item.

## Do not

- Do not let the worker call `correctResult`. The worker keys do not hold `STEWARD_ROLE`, and the
  decision is the steward's.
- Do not change how results are recorded: the relayer still writes only the first attested result
  of a game.
- Do not let the worker call `voidGame` either: it is a steward decision, the reminder only
  prepares the call.
- Do not try to move a started game on-chain by any other route (a new round, a lock move): its
  start time is fixed by design.
