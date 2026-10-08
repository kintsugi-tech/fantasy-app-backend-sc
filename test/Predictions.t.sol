// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IPredictions} from "../contracts/interfaces/IPredictions.sol";
import {IResultsRegistry} from "../contracts/interfaces/IResultsRegistry.sol";
import {Predictions} from "../contracts/Predictions.sol";
import {ResultsRegistry} from "../contracts/ResultsRegistry.sol";
import {M2Base} from "./utils/M2Base.sol";

contract PredictionsTest is M2Base {
    uint256 internal constant SECP256K1_N =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    bytes32[] internal games;
    bytes32 internal roundId;
    uint64 internal opensAt;
    uint64 internal lockTime;

    uint8 internal constant H = 1;
    uint8 internal constant A = 2;
    uint8 internal constant D = 3;

    function setUp() public override {
        super.setUp();
        _createLeague();
        opensAt = T0;
        lockTime = T0 + 2 days;
        games = _registerGames(3, lockTime); // a start exactly at the lock is allowed
        roundId = _scheduleRound(1, games, opensAt, lockTime);
        vm.warp(T0 + 1 hours);
    }

    // --- scheduling ------------------------------------------------------------

    function test_ScheduleRoundStoresRound() public view {
        Predictions.Round memory r = predictions.getRound(roundId);
        assertEq(roundId, predictions.roundIdOf(LEAGUE, 1));
        assertEq(r.leagueId, LEAGUE);
        assertEq(r.gamesHash, keccak256(abi.encodePacked(games)));
        assertEq(r.opensAt, opensAt);
        assertEq(r.lockTime, lockTime);
        assertEq(r.matchday, 1);
        assertEq(r.gameCount, 3);
        assertEq(uint8(r.state), uint8(Predictions.RoundState.Scheduled));
        assertEq(predictions.getRoundGames(roundId), games);
        assertEq(predictions.leagueRoundIds(LEAGUE).length, 1);
        assertEq(predictions.getLeague(LEAGUE).roundCount, 1);
        assertTrue(predictions.isRoundOpen(roundId));
    }

    function test_ScheduleRoundRejectsInvalidInput() public {
        bytes32[] memory more = _registerGames(2, lockTime + 1 days);
        uint64 lock2 = lockTime + 1 days;

        _expectSchedule(1, more, opensAt, lock2, abi.encodeWithSelector(Predictions.RoundExists.selector, roundId));
        _expectSchedule(
            2,
            new bytes32[](0),
            opensAt,
            lock2,
            abi.encodeWithSelector(Predictions.InvalidGameCount.selector, 0)
        );
        _expectSchedule(
            2,
            new bytes32[](33),
            opensAt,
            lock2,
            abi.encodeWithSelector(Predictions.InvalidGameCount.selector, 33)
        );
        _expectSchedule(2, more, lock2, lock2, abi.encodeWithSelector(Predictions.InvalidSchedule.selector));
        _expectSchedule(
            2,
            more,
            opensAt,
            uint64(block.timestamp),
            abi.encodeWithSelector(Predictions.InvalidSchedule.selector)
        );
        _expectSchedule(
            2,
            more,
            opensAt,
            lock2 + 1,
            abi.encodeWithSelector(Predictions.LockAfterStart.selector, more[0])
        );

        bytes32[] memory dup = new bytes32[](2);
        (dup[0], dup[1]) = (more[0], more[0]);
        _expectSchedule(2, dup, opensAt, lock2, abi.encodeWithSelector(Predictions.DuplicateGame.selector, more[0]));

        bytes32[] memory unknown = new bytes32[](1);
        unknown[0] = _gameId(9999);
        _expectSchedule(
            2,
            unknown,
            opensAt,
            lock2,
            abi.encodeWithSelector(Predictions.GameNotSchedulable.selector, unknown[0])
        );

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Predictions.LeagueNotActive.selector, keccak256("nope")));
        predictions.scheduleRound(keccak256("nope"), 2, opensAt, lock2, more);
    }

    function test_ScheduleRoundRejectsGameWithResult() public {
        bytes32[] memory more = _registerGames(1, uint64(block.timestamp) + 1 hours);
        vm.warp(block.timestamp + 1 hours);
        _record(_result(more[0], IResultsRegistry.GameStatus.Void, IResultsRegistry.Side.None, 0, 0));
        _expectSchedule(
            2,
            more,
            opensAt,
            lockTime + 1 days,
            abi.encodeWithSelector(Predictions.GameNotSchedulable.selector, more[0])
        );
    }

    function test_CreateLeagueIsUniqueAndOperatorOnly() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Predictions.LeagueExists.selector, LEAGUE));
        predictions.createLeague(LEAGUE, bytes32(0));

        bytes32 role = predictions.OPERATOR_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        predictions.createLeague(keccak256("other"), bytes32(0));
    }

    // --- submitFor -------------------------------------------------------------

    function test_SubmitStoresEntry() public {
        bytes memory picks = _picks(H, A, H);
        Predictions.BatchItem memory it = _item(aliceKey, alice, roundId, picks, uint64(block.timestamp));

        vm.expectEmit(address(predictions));
        emit Predictions.PredictionSubmitted(roundId, alice, it.picksHash, picks, it.confirmedAt);
        vm.prank(submitter);
        predictions.submitFor(alice, roundId, it.picksHash, picks, it.confirmedAt, it.signature);

        (uint64 confirmedAt, uint64 submittedAt, bytes memory stored) = predictions.getEntry(roundId, alice);
        assertEq(confirmedAt, it.confirmedAt);
        assertEq(submittedAt, block.timestamp);
        assertEq(stored, picks);
        assertTrue(predictions.hasSubmitted(roundId, alice));
        assertEq(predictions.getRound(roundId).submissions, 1);
        assertEq(it.picksHash, keccak256(abi.encode(roundId, keccak256(abi.encodePacked(games)), keccak256(picks))));
    }

    function test_SubmitRejectsDuplicate() public {
        _submit(aliceKey, alice, roundId, _picks(H, H, H));
        Predictions.BatchItem memory it = _item(aliceKey, alice, roundId, _picks(A, A, A), uint64(block.timestamp));
        _expectRejected(it, Predictions.SubmitStatus.Duplicate);
    }

    function test_SubmitRejectsInvalidPicks() public {
        uint64 now_ = uint64(block.timestamp);
        _expectRejected(_item(aliceKey, alice, roundId, abi.encodePacked(H, A), now_), Predictions.SubmitStatus.InvalidPicks);
        _expectRejected(_item(aliceKey, alice, roundId, _picks(H, 0, A), now_), Predictions.SubmitStatus.InvalidPicks);
        _expectRejected(_item(aliceKey, alice, roundId, _picks(H, 4, A), now_), Predictions.SubmitStatus.InvalidPicks);
    }

    function test_SubmitRejectsPicksHashMismatch() public {
        Predictions.BatchItem memory it = _item(aliceKey, alice, roundId, _picks(H, H, H), uint64(block.timestamp));
        it.picks = _picks(A, A, A); // signed hash no longer matches the picks sent
        _expectRejected(it, Predictions.SubmitStatus.PicksHashMismatch);
    }

    function test_SubmitRejectsZeroUser() public {
        Predictions.BatchItem memory it = _item(aliceKey, alice, roundId, _picks(H, H, H), uint64(block.timestamp));
        it.user = address(0);
        _expectRejected(it, Predictions.SubmitStatus.InvalidUser);
    }

    function test_SubmitRejectsConfirmedAtOutsideWindow() public {
        _expectRejected(
            _item(aliceKey, alice, roundId, _picks(H, H, H), opensAt - 1),
            Predictions.SubmitStatus.InvalidConfirmedAt
        );
        _expectRejected(
            _item(aliceKey, alice, roundId, _picks(H, H, H), uint64(block.timestamp) + 61),
            Predictions.SubmitStatus.InvalidConfirmedAt
        );
        vm.warp(lockTime - 10);
        _expectRejected(
            _item(aliceKey, alice, roundId, _picks(H, H, H), lockTime),
            Predictions.SubmitStatus.InvalidConfirmedAt
        );
        // Small clock skew is tolerated.
        Predictions.BatchItem memory skewed = _item(aliceKey, alice, roundId, _picks(H, H, H), lockTime - 1);
        vm.prank(submitter);
        predictions.submitFor(alice, roundId, skewed.picksHash, skewed.picks, skewed.confirmedAt, skewed.signature);
    }

    function test_SubmitRejectsBadSignatures() public {
        uint64 now_ = uint64(block.timestamp);
        Predictions.BatchItem memory it = _item(aliceKey, alice, roundId, _picks(H, A, H), now_);

        Predictions.BatchItem memory wrongSigner = _item(bobKey, alice, roundId, _picks(H, A, H), now_);
        _expectRejected(wrongSigner, Predictions.SubmitStatus.InvalidSignature);

        Predictions.BatchItem memory otherTime = _copy(it);
        otherTime.confirmedAt = now_ - 1; // valid window, but not what was signed
        _expectRejected(otherTime, Predictions.SubmitStatus.InvalidSignature);

        Predictions.BatchItem memory shortSig = _copy(it);
        shortSig.signature = abi.encodePacked(bytes32(0), bytes32(0));
        _expectRejected(shortSig, Predictions.SubmitStatus.InvalidSignature);

        // Malleable twin (s' = n - s, v flipped): raw ecrecover still returns alice, so only the
        // high-s check can reject it.
        Predictions.BatchItem memory malleable = _copy(it);
        malleable.signature = _malleate(it.signature);
        bytes32 digest = predictions.submissionDigest(alice, roundId, it.picksHash, it.confirmedAt);
        assertEq(_rawRecover(digest, malleable.signature), alice);
        _expectRejected(malleable, Predictions.SubmitStatus.InvalidSignature);

        // The untouched original is still accepted.
        vm.prank(submitter);
        predictions.submitFor(alice, roundId, it.picksHash, it.picks, it.confirmedAt, it.signature);
    }

    function test_SignatureIsBoundToTheRound() public {
        bytes32[] memory more = _registerGames(3, lockTime + 1 days);
        bytes32 round2 = _scheduleRound(2, more, opensAt, lockTime + 1 days);
        Predictions.BatchItem memory it = _item(aliceKey, alice, roundId, _picks(H, A, H), uint64(block.timestamp));

        // Same payload replayed on another round: the round's games change picksHash...
        vm.prank(submitter);
        vm.expectRevert(
            abi.encodeWithSelector(
                Predictions.SubmissionRejected.selector,
                alice,
                Predictions.SubmitStatus.PicksHashMismatch
            )
        );
        predictions.submitFor(alice, round2, it.picksHash, it.picks, it.confirmedAt, it.signature);

        // ...and with the right picksHash the signature (over round 1) does not verify.
        bytes32 hash2 = predictions.computePicksHash(round2, it.picks);
        vm.prank(submitter);
        vm.expectRevert(
            abi.encodeWithSelector(
                Predictions.SubmissionRejected.selector,
                alice,
                Predictions.SubmitStatus.InvalidSignature
            )
        );
        predictions.submitFor(alice, round2, hash2, it.picks, it.confirmedAt, it.signature);
    }

    function test_SubmitRequiresOpenRound() public {
        bytes32[] memory more = _registerGames(3, lockTime + 3 days);
        bytes32 future = _scheduleRound(2, more, lockTime, lockTime + 3 days);
        Predictions.BatchItem memory early = _item(aliceKey, alice, future, _picks(H, H, H), uint64(block.timestamp));
        _expectNotOpen(future, early);

        Predictions.BatchItem memory late = _item(aliceKey, alice, roundId, _picks(H, H, H), uint64(block.timestamp));
        vm.warp(lockTime);
        _expectNotOpen(roundId, late);

        vm.warp(lockTime + 1 hours);
        Predictions.BatchItem memory afterCancel = _item(aliceKey, alice, future, _picks(H, H, H), uint64(block.timestamp));
        vm.prank(steward);
        predictions.cancelRound(future, "batch could not land");
        _expectNotOpen(future, afterCancel);
    }

    function test_SubmitOnlySubmitterAndNotPaused() public {
        Predictions.BatchItem memory it = _item(aliceKey, alice, roundId, _picks(H, H, H), uint64(block.timestamp));
        bytes32 role = predictions.SUBMITTER_ROLE();

        // A user holding their exported key still cannot submit directly.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        predictions.submitFor(alice, roundId, it.picksHash, it.picks, it.confirmedAt, it.signature);

        vm.prank(steward);
        predictions.pause();
        vm.prank(submitter);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        predictions.submitFor(alice, roundId, it.picksHash, it.picks, it.confirmedAt, it.signature);
    }

    // --- submitForBatch ----------------------------------------------------------

    function test_BatchSkipsInvalidItemsAndIsIdempotent() public {
        uint64 now_ = uint64(block.timestamp);
        Predictions.BatchItem[] memory items = new Predictions.BatchItem[](3);
        items[0] = _item(aliceKey, alice, roundId, _picks(H, A, H), now_);
        items[1] = _item(carolKey, bob, roundId, _picks(A, A, A), now_); // wrong key
        items[2] = _item(carolKey, carol, roundId, _picks(H, H, A), now_);

        vm.expectEmit(address(predictions));
        emit Predictions.SubmissionSkipped(roundId, bob, Predictions.SubmitStatus.InvalidSignature);
        vm.prank(submitter);
        Predictions.SubmitStatus[] memory statuses = predictions.submitForBatch(roundId, items);
        assertEq(uint8(statuses[0]), uint8(Predictions.SubmitStatus.Ok));
        assertEq(uint8(statuses[1]), uint8(Predictions.SubmitStatus.InvalidSignature));
        assertEq(uint8(statuses[2]), uint8(Predictions.SubmitStatus.Ok));
        assertEq(predictions.getRound(roundId).submissions, 2);

        vm.prank(submitter);
        statuses = predictions.submitForBatch(roundId, items);
        assertEq(uint8(statuses[0]), uint8(Predictions.SubmitStatus.Duplicate));
        assertEq(uint8(statuses[2]), uint8(Predictions.SubmitStatus.Duplicate));
        assertEq(predictions.getRound(roundId).submissions, 2);
    }

    function test_BatchBounds() public {
        vm.startPrank(submitter);
        vm.expectRevert(Predictions.EmptyBatch.selector);
        predictions.submitForBatch(roundId, new Predictions.BatchItem[](0));
        vm.expectRevert(abi.encodeWithSelector(Predictions.BatchTooLarge.selector, 101, 100));
        predictions.submitForBatch(roundId, new Predictions.BatchItem[](101));
        vm.stopPrank();
    }

    function test_BatchRevertsWhenRoundClosed() public {
        Predictions.BatchItem[] memory items = new Predictions.BatchItem[](1);
        items[0] = _item(aliceKey, alice, roundId, _picks(H, A, H), uint64(block.timestamp));
        vm.warp(lockTime);
        vm.prank(submitter);
        vm.expectRevert(abi.encodeWithSelector(Predictions.RoundNotOpen.selector, roundId));
        predictions.submitForBatch(roundId, items);
    }

    // --- updateRoundLock ---------------------------------------------------------

    function test_UpdateRoundLock() public {
        vm.prank(operator);
        predictions.updateRoundLock(roundId, lockTime - 1 hours);
        assertEq(predictions.getRound(roundId).lockTime, lockTime - 1 hours);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Predictions.LockAfterStart.selector, games[0]));
        predictions.updateRoundLock(roundId, lockTime + 1);

        vm.prank(operator);
        vm.expectRevert(Predictions.InvalidSchedule.selector);
        predictions.updateRoundLock(roundId, uint64(block.timestamp));

        vm.warp(lockTime - 1 hours);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Predictions.RoundLocked.selector, roundId));
        predictions.updateRoundLock(roundId, lockTime - 30 minutes);
    }

    /// C5: a lock moved earlier stays after every stored confirmedAt, so leagueStatsOf cannot
    /// underflow on `lockTime - confirmedAt`.
    function test_UpdateRoundLockStaysAfterSkewedConfirmations() public {
        uint64 now_ = uint64(block.timestamp);
        Predictions.BatchItem memory skewed = _item(aliceKey, alice, roundId, _picks(H, A, H), now_ + 50);
        vm.prank(submitter);
        predictions.submitFor(alice, roundId, skewed.picksHash, skewed.picks, skewed.confirmedAt, skewed.signature);

        vm.startPrank(operator);
        vm.expectRevert(Predictions.InvalidSchedule.selector);
        predictions.updateRoundLock(roundId, now_ + 30); // the report's case: before confirmedAt
        vm.expectRevert(Predictions.InvalidSchedule.selector);
        predictions.updateRoundLock(roundId, now_ + 60);
        predictions.updateRoundLock(roundId, now_ + 61);
        vm.stopPrank();

        vm.warp(lockTime + 3 hours);
        _settleGames(games, _bools(true, false, true));
        _finalizeRound(roundId);
        IPredictions.LeagueStats memory s = predictions.leagueStatsOf(LEAGUE, alice);
        assertEq(s.sumLeadTime, 11);
        assertEq(s.points, 3);
    }

    // --- finalization delay ------------------------------------------------------

    function test_FinalizationDelayCountsFromTheLastResult() public {
        assertEq(predictions.finalizableAt(roundId), 0); // no results yet
        assertEq(predictions.finalizableAt(keccak256("unknown")), 0);

        vm.warp(lockTime + 3 hours);
        _record(_final(games[0], true));
        assertEq(predictions.finalizableAt(roundId), 0); // two games still pending

        vm.warp(lockTime + 10 hours);
        IResultsRegistry.ResultInput[] memory batch = new IResultsRegistry.ResultInput[](2);
        batch[0] = _final(games[1], false);
        batch[1] = _final(games[2], true);
        vm.prank(resultsRelayer);
        registry.recordResults(batch);

        uint64 readyAt = lockTime + 10 hours + FINALIZATION_DELAY;
        assertEq(predictions.finalizableAt(roundId), readyAt);
        vm.warp(lockTime + 3 hours + FINALIZATION_DELAY); // a delay after the first result is not enough
        vm.expectRevert(abi.encodeWithSelector(Predictions.FinalizationPending.selector, roundId, readyAt));
        predictions.finalizeRound(roundId);

        vm.warp(readyAt);
        predictions.finalizeRound(roundId);
        assertEq(predictions.finalizableAt(roundId), 0); // finalized
    }

    /// Results recorded before the lock (games moved earlier) never make a round settle before it.
    function test_FinalizableAtIsNeverBeforeTheLock() public {
        vm.startPrank(operator);
        for (uint256 i = 0; i < 3; ++i) registry.rescheduleGame(games[i], T0 + 2 hours);
        vm.stopPrank();
        vm.warp(T0 + 3 hours);
        _settleGames(games, _bools(true, true, true));
        assertEq(predictions.finalizableAt(roundId), lockTime);

        vm.warp(lockTime);
        predictions.finalizeRound(roundId);
        assertEq(predictions.getRound(roundId).outcomes, 0); // all moved before the lock: none counts
    }

    /// The window is what makes a wrong result fixable: the steward cancels the round in it.
    function test_StewardCancelsWithinTheWindow() public {
        _submit(aliceKey, alice, roundId, _picks(H, H, H));
        vm.warp(lockTime + 3 hours);
        _settleGames(games, _bools(true, true, false)); // say game 3 was matched to the wrong file

        vm.prank(steward);
        predictions.cancelRound(roundId, "game 3 result attached to the wrong game");
        vm.warp(block.timestamp + FINALIZATION_DELAY);
        vm.expectRevert(abi.encodeWithSelector(Predictions.RoundNotActive.selector, roundId));
        predictions.finalizeRound(roundId);
        _assertScore(alice, 0, 0);
    }

    function test_SetFinalizationDelay() public {
        bytes32 role = predictions.DEFAULT_ADMIN_ROLE();
        vm.prank(steward);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, steward, role));
        predictions.setFinalizationDelay(2 hours);

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(Predictions.DelayOutOfRange.selector, uint64(1 hours - 1)));
        predictions.setFinalizationDelay(1 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(Predictions.DelayOutOfRange.selector, uint64(7 days + 1)));
        predictions.setFinalizationDelay(7 days + 1);
        vm.expectEmit(address(predictions));
        emit Predictions.FinalizationDelaySet(1 hours);
        predictions.setFinalizationDelay(1 hours);
        vm.stopPrank();

        // It applies to rounds already waiting.
        vm.warp(lockTime + 3 hours);
        _settleGames(games, _bools(true, true, true));
        assertEq(predictions.finalizableAt(roundId), lockTime + 4 hours);
    }

    // --- finalizeRound & scoring -------------------------------------------------

    function test_FinalizeRoundScoresPicks() public {
        _submit(aliceKey, alice, roundId, _picks(H, A, H));
        _submit(bobKey, bob, roundId, _picks(A, A, A));

        vm.expectRevert(abi.encodeWithSelector(Predictions.RoundNotLocked.selector, roundId));
        predictions.finalizeRound(roundId);

        vm.warp(lockTime + 3 hours);
        IResultsRegistry.ResultInput[] memory batch = new IResultsRegistry.ResultInput[](2);
        batch[0] = _final(games[0], true);
        batch[1] = _final(games[1], false);
        vm.prank(resultsRelayer);
        registry.recordResults(batch);

        vm.expectRevert(abi.encodeWithSelector(Predictions.GameNotFinal.selector, games[2]));
        predictions.finalizeRound(roundId);

        // Results are final right away; the round settles a full delay after the last one.
        _record(_final(games[2], true));
        uint64 readyAt = uint64(block.timestamp) + FINALIZATION_DELAY;
        assertEq(predictions.finalizableAt(roundId), readyAt);
        vm.warp(readyAt - 1);
        vm.expectRevert(abi.encodeWithSelector(Predictions.FinalizationPending.selector, roundId, readyAt));
        predictions.finalizeRound(roundId);

        vm.warp(readyAt);
        vm.expectEmit(address(predictions));
        emit Predictions.RoundFinalized(roundId, uint64(1 | (2 << 2) | (1 << 4)), 3);
        vm.prank(stranger); // permissionless
        predictions.finalizeRound(roundId);

        _assertScore(alice, 3, 3);
        _assertScore(bob, 1, 3);
        _assertScore(carol, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(Predictions.RoundNotActive.selector, roundId));
        predictions.finalizeRound(roundId);
    }

    function test_FinalizeRoundExcludesVoidAndEarlyGames() public {
        _submit(aliceKey, alice, roundId, _picks(H, A, H));

        // Game 3 is moved before the lock (after picks were made): it must not count.
        vm.prank(operator);
        registry.rescheduleGame(games[2], lockTime - 1 hours);

        vm.warp(lockTime + 3 hours);
        _record(_final(games[0], true));
        _record(_result(games[1], IResultsRegistry.GameStatus.Void, IResultsRegistry.Side.None, 0, 0));
        _record(_final(games[2], true));

        _finalizeRound(roundId);
        assertEq(predictions.getRound(roundId).outcomes, 1);
        _assertScore(alice, 1, 1);
    }

    /// C1: once picks are locked no move can drop a game from the score, because a new start time
    /// must be in the future and therefore after the lock.
    function test_GameCannotBeDroppedAfterLock() public {
        _submit(aliceKey, alice, roundId, _picks(H, A, H));
        vm.warp(lockTime + 1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.StartTimeInPast.selector, games[0], lockTime - 1));
        registry.rescheduleGame(games[0], lockTime - 1);

        // Postponing to a later date still works, and the game keeps counting.
        vm.prank(operator);
        registry.rescheduleGame(games[0], lockTime + 1 days);
        vm.warp(lockTime + 1 days + 3 hours);
        _settleGames(games, _bools(true, false, true));
        _finalizeRound(roundId);
        _assertScore(alice, 3, 3);
    }

    /// MAX_GAMES: a full 32-game round, the limit of the 2-bit packing in a uint64.
    function test_ThirtyTwoGameRound() public {
        uint64 lock = lockTime + 1 days;
        bytes32[] memory g32 = _registerGames(32, lock);
        bytes32 round32 = _scheduleRound(2, g32, opensAt, lock);

        bytes memory picks = new bytes(32);
        for (uint256 i = 0; i < 32; ++i) picks[i] = bytes1(i % 2 == 0 ? H : A);
        _submit(aliceKey, alice, round32, picks);
        (, , bytes memory stored) = predictions.getEntry(round32, alice);
        assertEq(stored, picks);

        // Home wins every game whose index is not a multiple of 3; the last game is void.
        vm.warp(lock + 3 hours);
        IResultsRegistry.ResultInput[] memory batch = new IResultsRegistry.ResultInput[](32);
        uint8 expectedCorrect;
        for (uint256 i = 0; i < 31; ++i) {
            bool homeWins = i % 3 != 0;
            batch[i] = _final(g32[i], homeWins);
            if ((uint8(picks[i]) == H) == homeWins) ++expectedCorrect;
        }
        batch[31] = _result(g32[31], IResultsRegistry.GameStatus.Void, IResultsRegistry.Side.None, 0, 0);
        vm.prank(resultsRelayer);
        registry.recordResults(batch);
        _finalizeRound(round32);

        (uint8 correct, uint8 counted) = predictions.scoreOf(round32, alice);
        assertEq(counted, 31);
        assertEq(correct, expectedCorrect);
        uint64 outcomes = predictions.getRound(round32).outcomes;
        assertEq(outcomes >> 62, 0); // game 32 (void) in the top two bits
        assertEq((outcomes >> 60) & 3, 2); // game 31 (index 30, a multiple of 3): away win
        assertEq((outcomes >> 58) & 3, 1); // game 30 (index 29): home win
    }

    /// A format with draws (open score; not volleyball, but no contract change needed): a draw pick
    /// scores on a drawn game. On a game without draws it is accepted but can never match, since
    /// the registry never records a draw there.
    function test_DrawPicks() public {
        uint64 lock = lockTime + 1 days;
        bytes32[] memory withDraws = _registerGames(2, lock, 0, true);
        bytes32[] memory ids = new bytes32[](3);
        (ids[0], ids[1], ids[2]) = (withDraws[0], withDraws[1], _registerGames(1, lock)[0]);
        bytes32 round2 = _scheduleRound(2, ids, opensAt, lock);

        _submit(aliceKey, alice, round2, _picks(D, D, D));
        _submit(bobKey, bob, round2, _picks(D, H, A));
        (, , bytes memory stored) = predictions.getEntry(round2, alice);
        assertEq(stored, _picks(D, D, D));

        vm.warp(lock + 3 hours);
        _record(_draw(ids[0]));
        _record(_result(ids[1], IResultsRegistry.GameStatus.Final, IResultsRegistry.Side.Home, 2, 0));
        _record(_final(ids[2], false));
        _finalizeRound(round2);

        assertEq(predictions.getRound(round2).outcomes, uint64(3 | (1 << 2) | (2 << 4)));
        (uint8 correct, uint8 counted) = predictions.scoreOf(round2, alice);
        assertEq(correct, 1);
        assertEq(counted, 3);
        (correct, counted) = predictions.scoreOf(round2, bob);
        assertEq(correct, 3);
        assertEq(counted, 3);
    }

    function test_ForfeitCounts() public {
        _submit(aliceKey, alice, roundId, _picks(A, A, A));
        vm.warp(lockTime + 3 hours);
        _record(_result(games[0], IResultsRegistry.GameStatus.Forfeit, IResultsRegistry.Side.Away, 0, 3));
        _record(_final(games[1], false));
        _record(_final(games[2], true));
        _finalizeRound(roundId);
        _assertScore(alice, 2, 3);
    }

    function test_CancelRound() public {
        bytes32 role = predictions.STEWARD_ROLE();
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, role));
        predictions.cancelRound(roundId, "no");

        vm.prank(steward);
        predictions.cancelRound(roundId, "venue unavailable");
        assertEq(uint8(predictions.getRound(roundId).state), uint8(Predictions.RoundState.Cancelled));

        vm.warp(lockTime + 1);
        vm.expectRevert(abi.encodeWithSelector(Predictions.RoundNotActive.selector, roundId));
        predictions.finalizeRound(roundId);
    }

    // --- league stats & standings ------------------------------------------------

    function test_LeagueStatsAcrossRounds() public {
        bytes32[] memory g2 = _registerGames(3, lockTime + 2 days);
        bytes32 round2 = _scheduleRound(2, g2, opensAt, lockTime + 2 days);
        bytes32[] memory g3 = _registerGames(3, lockTime + 4 days);
        bytes32 round3 = _scheduleRound(3, g3, opensAt, lockTime + 4 days);

        vm.warp(lockTime - 1 hours);
        _submit(aliceKey, alice, roundId, _picks(H, H, H)); // lead time 1h
        _submit(bobKey, bob, roundId, _picks(A, A, A));
        _submit(aliceKey, alice, round2, _picks(H, A, H)); // lead time 2d + 1h
        _submit(aliceKey, alice, round3, _picks(H, H, H)); // round 3 will be all void

        vm.warp(lockTime + 3 hours);
        _settleGames(games, _bools(true, true, false)); // alice 2/3, bob 1/3
        _finalizeRound(roundId);

        vm.warp(lockTime + 2 days + 3 hours);
        _settleGames(g2, _bools(true, false, true)); // alice 3/3
        _finalizeRound(round2);

        vm.warp(lockTime + 4 days);
        for (uint256 i = 0; i < 3; ++i) {
            _record(_result(g3[i], IResultsRegistry.GameStatus.Void, IResultsRegistry.Side.None, 0, 0));
        }
        _finalizeRound(round3);

        IPredictions.LeagueStats memory s = predictions.leagueStatsOf(LEAGUE, alice);
        assertEq(s.points, 5);
        assertEq(s.correct, 5);
        assertEq(s.counted, 6);
        assertEq(s.roundsPlayed, 2); // the all-void round does not count as played
        assertEq(s.sumLeadTime, 1 hours + (2 days + 1 hours));

        IPredictions.LeagueStats memory b = predictions.leagueStatsOf(LEAGUE, bob);
        assertEq(b.points, 1);
        assertEq(b.roundsPlayed, 1);
    }

    function test_StandingsAreProposedThenFinalizedOnce() public {
        bytes32 root = keccak256("root");
        vm.prank(steward);
        vm.expectRevert(abi.encodeWithSelector(Predictions.RoundsPending.selector, LEAGUE));
        predictions.proposeStandings(LEAGUE, root, 10, keccak256("report"), "ipfs://report");

        _submit(aliceKey, alice, roundId, _picks(H, H, H));
        vm.warp(lockTime + 3 hours);
        _settleGames(games, _bools(true, true, true));
        _finalizeRound(roundId);

        vm.startPrank(steward);
        vm.expectRevert(abi.encodeWithSelector(Predictions.NoStandingsProposal.selector, LEAGUE));
        predictions.finalizeLeague(LEAGUE);
        vm.expectRevert(Predictions.InvalidStandings.selector);
        predictions.proposeStandings(LEAGUE, bytes32(0), 10, keccak256("report"), "ipfs://report");

        uint64 proposedAt = uint64(block.timestamp);
        uint64 finalizableAt = proposedAt + 48 hours;
        vm.expectEmit(address(predictions));
        emit Predictions.StandingsProposed(LEAGUE, root, 10, keccak256("report"), "ipfs://report", finalizableAt);
        predictions.proposeStandings(LEAGUE, root, 10, keccak256("report"), "ipfs://report");
        IPredictions.StandingsProposal memory p = predictions.getStandingsProposal(LEAGUE);
        assertEq(p.standingsRoot, root);
        assertEq(p.proposedAt, proposedAt);
        assertEq(p.roundCount, 1);
        assertFalse(predictions.getLeague(LEAGUE).finalized);

        vm.warp(finalizableAt - 1);
        vm.expectRevert(abi.encodeWithSelector(Predictions.ReviewPeriodOpen.selector, LEAGUE, finalizableAt));
        predictions.finalizeLeague(LEAGUE);

        vm.warp(finalizableAt);
        vm.expectEmit(address(predictions));
        emit Predictions.LeagueFinalized(LEAGUE, root, 10, keccak256("report"));
        predictions.finalizeLeague(LEAGUE);
        vm.stopPrank();

        IPredictions.League memory l = predictions.getLeague(LEAGUE);
        assertTrue(l.finalized);
        assertEq(l.standingsRoot, root);
        assertEq(l.totalPlayers, 10);
        assertEq(l.reportHash, keccak256("report"));
        assertEq(l.finalizedAt, block.timestamp);

        // No more rounds once finalized.
        bytes32[] memory more = _registerGames(1, uint64(block.timestamp) + 1 days);
        _expectSchedule(
            2,
            more,
            uint64(block.timestamp),
            uint64(block.timestamp) + 1 days,
            abi.encodeWithSelector(Predictions.LeagueNotActive.selector, LEAGUE)
        );

        // The standings are anchored once: no new proposal, no second finalization.
        vm.startPrank(steward);
        vm.expectRevert(abi.encodeWithSelector(Predictions.LeagueNotActive.selector, LEAGUE));
        predictions.proposeStandings(LEAGUE, keccak256("root2"), 11, keccak256("report2"), "ipfs://report2");
        vm.expectRevert(abi.encodeWithSelector(Predictions.LeagueNotActive.selector, LEAGUE));
        predictions.finalizeLeague(LEAGUE);
        vm.stopPrank();
        assertEq(predictions.getLeague(LEAGUE).standingsRoot, root);
    }

    /// A wrong proposal is replaced during the review; the replacement restarts the period.
    function test_NewProposalReplacesAndRestartsTheReview() public {
        vm.warp(lockTime + 3 hours);
        _settleGames(games, _bools(true, true, true));
        _finalizeRound(roundId);

        vm.startPrank(steward);
        predictions.proposeStandings(LEAGUE, keccak256("wrong"), 10, keccak256("report"), "ipfs://wrong");
        vm.warp(block.timestamp + 47 hours);
        predictions.proposeStandings(LEAGUE, keccak256("right"), 10, keccak256("report2"), "ipfs://right");
        uint64 finalizableAt = uint64(block.timestamp) + 48 hours;

        vm.warp(block.timestamp + 2 hours); // 49 h after the first proposal
        vm.expectRevert(abi.encodeWithSelector(Predictions.ReviewPeriodOpen.selector, LEAGUE, finalizableAt));
        predictions.finalizeLeague(LEAGUE);
        vm.warp(finalizableAt);
        predictions.finalizeLeague(LEAGUE);
        vm.stopPrank();
        assertEq(predictions.getLeague(LEAGUE).standingsRoot, keccak256("right"));
        assertEq(predictions.getLeague(LEAGUE).reportHash, keccak256("report2"));
    }

    /// A round scheduled after the proposal is not in the proposed standings: they cannot be
    /// finalized, even once that round is settled, until the steward proposes again.
    function test_RoundAddedDuringReviewOutdatesTheProposal() public {
        vm.warp(lockTime + 3 hours);
        _settleGames(games, _bools(true, true, true));
        _finalizeRound(roundId);
        vm.prank(steward);
        predictions.proposeStandings(LEAGUE, keccak256("root"), 10, bytes32(0), "");

        uint64 lock2 = uint64(block.timestamp) + 1 hours;
        bytes32[] memory more = _registerGames(1, lock2);
        bytes32 round2 = _scheduleRound(2, more, uint64(block.timestamp), lock2);
        vm.warp(lock2 + 3 hours);
        _record(_final(more[0], true));
        _finalizeRound(round2);
        vm.warp(block.timestamp + 48 hours);

        vm.startPrank(steward);
        vm.expectRevert(abi.encodeWithSelector(Predictions.StandingsOutdated.selector, LEAGUE));
        predictions.finalizeLeague(LEAGUE);
        predictions.proposeStandings(LEAGUE, keccak256("root2"), 10, bytes32(0), "");
        vm.warp(block.timestamp + 48 hours);
        predictions.finalizeLeague(LEAGUE);
        vm.stopPrank();
        assertEq(predictions.getLeague(LEAGUE).standingsRoot, keccak256("root2"));
    }

    function test_ProposeStandingsNeedsAFinalizedRound() public {
        vm.prank(steward);
        predictions.cancelRound(roundId, "cancelled");
        vm.prank(steward);
        vm.expectRevert(abi.encodeWithSelector(Predictions.RoundsPending.selector, LEAGUE));
        predictions.proposeStandings(LEAGUE, keccak256("root"), 1, bytes32(0), "");
    }

    /// Anyone can check a row against the proposed root during the review, then the anchored one.
    function test_CheckStandingAgainstProposalThenAnchor() public {
        (IPredictions.StandingLeaf memory a, IPredictions.StandingLeaf memory b) = _settleTwoPlayers();
        (bool inTree, bool matchesChain) = predictions.checkStanding(LEAGUE, a, _proof(b));
        assertFalse(inTree); // nothing proposed yet
        assertTrue(matchesChain);

        vm.prank(steward);
        predictions.proposeStandings(LEAGUE, _root(a, b), 2, bytes32(0), "");
        (inTree, matchesChain) = predictions.checkStanding(LEAGUE, a, _proof(b));
        assertTrue(inTree && matchesChain);

        vm.warp(block.timestamp + 48 hours);
        vm.prank(steward);
        predictions.finalizeLeague(LEAGUE);
        (inTree, matchesChain) = predictions.checkStanding(LEAGUE, b, _proof(a));
        assertTrue(inTree && matchesChain);

        // A wrong proof, or another league's row, is not in the tree.
        (inTree, ) = predictions.checkStanding(LEAGUE, a, _proof(a));
        assertFalse(inTree);
        IPredictions.StandingLeaf memory other = IPredictions.StandingLeaf(keccak256("other"), alice, 1, 2, 2, 3, 1, 1 hours);
        (inTree, ) = predictions.checkStanding(LEAGUE, other, _proof(b));
        assertFalse(inTree);
    }

    /// A row that is in the tree but disagrees with the chain is provably wrong.
    function test_CheckStandingExposesAWrongRow() public {
        (IPredictions.StandingLeaf memory a, ) = _settleTwoPlayers();
        IPredictions.StandingLeaf memory inflated = IPredictions.StandingLeaf(LEAGUE, bob, 1, 3, 3, 3, 1, 1 hours);
        vm.prank(steward);
        predictions.proposeStandings(LEAGUE, _root(a, inflated), 2, bytes32(0), "");
        (bool inTree, bool matchesChain) = predictions.checkStanding(LEAGUE, inflated, _proof(a));
        assertTrue(inTree);
        assertFalse(matchesChain);
    }

    // --- fuzz ----------------------------------------------------------------------

    function testFuzz_PickValues(uint8 a, uint8 b, uint8 c) public {
        Predictions.BatchItem memory it = _item(aliceKey, alice, roundId, _picks(a, b, c), uint64(block.timestamp));
        bool valid = (a >= H && a <= D) && (b >= H && b <= D) && (c >= H && c <= D);
        Predictions.BatchItem[] memory items = new Predictions.BatchItem[](1);
        items[0] = it;
        vm.prank(submitter);
        Predictions.SubmitStatus[] memory statuses = predictions.submitForBatch(roundId, items);
        if (valid) {
            assertEq(uint8(statuses[0]), uint8(Predictions.SubmitStatus.Ok));
            (, , bytes memory stored) = predictions.getEntry(roundId, alice);
            assertEq(stored, it.picks);
        } else {
            assertEq(uint8(statuses[0]), uint8(Predictions.SubmitStatus.InvalidPicks));
        }
    }

    function testFuzz_ConfirmedAtWindow(uint64 nowOffset, uint64 confirmedAt) public {
        uint64 now_ = opensAt + (nowOffset % (lockTime - opensAt)); // any moment the round is open
        vm.warp(now_);
        Predictions.BatchItem[] memory items = new Predictions.BatchItem[](1);
        items[0] = _item(aliceKey, alice, roundId, _picks(H, A, H), confirmedAt);
        vm.prank(submitter);
        Predictions.SubmitStatus[] memory statuses = predictions.submitForBatch(roundId, items);

        bool valid = confirmedAt >= opensAt && confirmedAt < lockTime && uint256(confirmedAt) <= uint256(now_) + 60;
        assertEq(
            uint8(statuses[0]),
            uint8(valid ? Predictions.SubmitStatus.Ok : Predictions.SubmitStatus.InvalidConfirmedAt)
        );
    }

    function testFuzz_ScoreMatchesManualCount(uint8 pickBits, uint8 winBits, uint8 voidBits) public {
        bytes memory picks = new bytes(3);
        bool[] memory homeWins = new bool[](3);
        for (uint256 i = 0; i < 3; ++i) {
            picks[i] = bytes1((pickBits >> i) & 1 == 1 ? H : A);
            homeWins[i] = (winBits >> i) & 1 == 1;
        }
        _submit(aliceKey, alice, roundId, picks);

        vm.warp(lockTime + 3 hours);
        uint8 expectedCorrect;
        uint8 expectedCounted;
        for (uint256 i = 0; i < 3; ++i) {
            if ((voidBits >> i) & 1 == 1) {
                _record(_result(games[i], IResultsRegistry.GameStatus.Void, IResultsRegistry.Side.None, 0, 0));
                continue;
            }
            _record(_final(games[i], homeWins[i]));
            ++expectedCounted;
            if (uint8(picks[i]) == (homeWins[i] ? H : A)) ++expectedCorrect;
        }
        _finalizeRound(roundId);
        _assertScore(alice, expectedCorrect, expectedCounted);
    }

    // --- helpers -------------------------------------------------------------------

    /// @dev OZ StandardMerkleTree leaf: keccak256(bytes.concat(keccak256(abi.encode(row)))).
    function _leafHash(IPredictions.StandingLeaf memory leaf) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(leaf))));
    }

    /// @dev Root of a two-row StandardMerkleTree (sorted pair); a row's proof is the other's hash.
    function _root(IPredictions.StandingLeaf memory x, IPredictions.StandingLeaf memory y) internal pure returns (bytes32) {
        (bytes32 hx, bytes32 hy) = (_leafHash(x), _leafHash(y));
        return hx < hy ? keccak256(abi.encode(hx, hy)) : keccak256(abi.encode(hy, hx));
    }

    function _proof(IPredictions.StandingLeaf memory sibling) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = _leafHash(sibling);
    }

    /// @dev alice 2/3 and bob 1/3 in round 1, both confirmed 1 h before the lock.
    function _settleTwoPlayers()
        internal
        returns (IPredictions.StandingLeaf memory a, IPredictions.StandingLeaf memory b)
    {
        vm.warp(lockTime - 1 hours);
        _submit(aliceKey, alice, roundId, _picks(H, H, H));
        _submit(bobKey, bob, roundId, _picks(A, A, A));
        vm.warp(lockTime + 3 hours);
        _settleGames(games, _bools(true, true, false));
        _finalizeRound(roundId);
        a = IPredictions.StandingLeaf(LEAGUE, alice, 1, 2, 2, 3, 1, 1 hours);
        b = IPredictions.StandingLeaf(LEAGUE, bob, 2, 1, 1, 3, 1, 1 hours);
    }

    function _assertScore(address user, uint8 correct, uint8 counted) internal view {
        (uint8 c, uint8 n) = predictions.scoreOf(roundId, user);
        assertEq(c, correct, "correct");
        assertEq(n, counted, "counted");
    }

    function _expectRejected(Predictions.BatchItem memory it, Predictions.SubmitStatus status) internal {
        vm.prank(submitter);
        vm.expectRevert(abi.encodeWithSelector(Predictions.SubmissionRejected.selector, it.user, status));
        predictions.submitFor(it.user, roundId, it.picksHash, it.picks, it.confirmedAt, it.signature);
    }

    function _expectNotOpen(bytes32 id, Predictions.BatchItem memory it) internal {
        vm.prank(submitter);
        vm.expectRevert(abi.encodeWithSelector(Predictions.RoundNotOpen.selector, id));
        predictions.submitFor(it.user, id, it.picksHash, it.picks, it.confirmedAt, it.signature);
    }

    function _expectSchedule(
        uint16 matchday,
        bytes32[] memory ids,
        uint64 opens,
        uint64 lock,
        bytes memory err
    ) internal {
        vm.prank(operator);
        vm.expectRevert(err);
        predictions.scheduleRound(LEAGUE, matchday, opens, lock, ids);
    }

    function _copy(Predictions.BatchItem memory it) internal pure returns (Predictions.BatchItem memory) {
        return Predictions.BatchItem(it.user, it.picksHash, it.picks, it.confirmedAt, it.signature);
    }

    function _split(bytes memory sig) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        assembly {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
    }

    function _malleate(bytes memory sig) internal pure returns (bytes memory) {
        (bytes32 r, bytes32 s, uint8 v) = _split(sig);
        return abi.encodePacked(r, bytes32(SECP256K1_N - uint256(s)), v == 27 ? uint8(28) : uint8(27));
    }

    function _rawRecover(bytes32 digest, bytes memory sig) internal pure returns (address) {
        (bytes32 r, bytes32 s, uint8 v) = _split(sig);
        return ecrecover(digest, v, r, s);
    }
}
