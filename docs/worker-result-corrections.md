# Handoff: adapt the worker to result corrections and the standings lock

For: an agent working in `injective-m2-frontend` (sibling of this repo). Do the steps in order.
The contracts, tests, deploy files and README are already done in `injective-m2-backend`. Read the
"How it works", "Key rules" and "Pause and incidents" sections of its README first.

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

### 5. Docs

- Frontend `README.md`, around line 52 ("A recorded result is final … only opens a
  `result_conflict` item"). Update it: the steward can correct a result once, within
  `correctableUntil`, and the inbox gives the ready-made call.
- Any steward runbook in the frontend repo: same incident procedure as the backend README's
  "Pause and incidents".

### 6. Tests

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

## Do not

- Do not let the worker call `correctResult`. The worker keys do not hold `STEWARD_ROLE`, and the
  decision is the steward's.
- Do not change how results are recorded: the relayer still writes only the first attested result
  of a game.
