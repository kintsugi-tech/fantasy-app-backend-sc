// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {IPredictions} from "../contracts/interfaces/IPredictions.sol";
import {IResultsRegistry} from "../contracts/interfaces/IResultsRegistry.sol";
import {Predictions} from "../contracts/Predictions.sol";
import {ResultsRegistry} from "../contracts/ResultsRegistry.sol";
import {M2Base} from "./utils/M2Base.sol";

/// @dev Drives random sequences against one league of 3 rounds of 3 games: submissions (valid or
///      not, with confirmedAt up to MAX_CLOCK_SKEW ahead), time jumps, game moves, lock moves,
///      results (Final or Void, game by game), steward corrections, admin changes of the two
///      settlement windows, cancellations and finalization. The combinations of these, not each
///      function alone, are what the invariants check.
contract PredictionsHandler is Test {
    uint256 internal constant GAMES = 3;

    Predictions internal immutable predictions;
    ResultsRegistry internal immutable registry;
    address internal immutable operator;
    address internal immutable submitter;
    address internal immutable resultsRelayer;
    address internal immutable steward;
    address internal immutable admin;

    bytes32[] public roundIds;
    mapping(bytes32 roundId => bytes32[]) internal _games;
    address[] public users;
    uint256[] internal keys;

    mapping(bytes32 roundId => mapping(address user => bytes)) public storedPicks;
    mapping(bytes32 roundId => mapping(address user => uint64)) public storedConfirmedAt;
    mapping(bytes32 roundId => uint256) public accepted;
    mapping(bytes32 roundId => uint64) public outcomesAtFinalization;
    /// A game seen tipping off at or after its round's lock once the round was locked: it was
    /// played after picks closed, so it must count.
    mapping(bytes32 gameId => bool) public lockedIn;

    constructor(
        Predictions predictions_,
        ResultsRegistry registry_,
        address[5] memory roles, // operator, submitter, results relayer, steward, admin
        bytes32[] memory roundIds_,
        bytes32[][] memory games_
    ) {
        predictions = predictions_;
        registry = registry_;
        (operator, submitter, resultsRelayer, steward, admin) = (roles[0], roles[1], roles[2], roles[3], roles[4]);
        for (uint256 r = 0; r < roundIds_.length; ++r) {
            roundIds.push(roundIds_[r]);
            _games[roundIds_[r]] = games_[r];
        }
        for (uint256 i = 0; i < 5; ++i) {
            (address user, uint256 key) = makeAddrAndKey(string.concat("player", vm.toString(i)));
            users.push(user);
            keys.push(key);
        }
    }

    function usersLength() external view returns (uint256) {
        return users.length;
    }

    function roundsLength() external view returns (uint256) {
        return roundIds.length;
    }

    function gameOf(bytes32 roundId, uint256 i) external view returns (bytes32) {
        return _games[roundId][i];
    }

    // --- actions ---------------------------------------------------------------------------

    function submit(uint256 userSeed, uint256 roundSeed, uint8 pickBits, uint32 age, bool wrongKey) external {
        bytes32 roundId = _round(roundSeed);
        if (!predictions.isRoundOpen(roundId)) return;
        Predictions.Round memory r = predictions.getRound(roundId);
        uint256 u = userSeed % users.length;
        address user = users[u];

        bytes memory picks = new bytes(GAMES);
        for (uint256 i = 0; i < GAMES; ++i) picks[i] = bytes1((pickBits >> i) & 1 == 1 ? uint8(1) : uint8(2));
        // From one hour ago up to MAX_CLOCK_SKEW ahead, inside [opensAt, lockTime).
        uint64 confirmedAt = uint64(block.timestamp) + 60 - uint64(age % (1 hours + 61));
        if (confirmedAt < r.opensAt) confirmedAt = r.opensAt;
        if (confirmedAt >= r.lockTime) confirmedAt = r.lockTime - 1;

        bytes32 picksHash = predictions.computePicksHash(roundId, picks);
        bytes32 digest = predictions.submissionDigest(user, roundId, picksHash, confirmedAt);
        (uint8 v, bytes32 rs, bytes32 s) = vm.sign(wrongKey ? keys[(u + 1) % keys.length] : keys[u], digest);

        Predictions.BatchItem[] memory items = new Predictions.BatchItem[](1);
        items[0] = Predictions.BatchItem(user, picksHash, picks, confirmedAt, abi.encodePacked(rs, s, v));
        vm.prank(submitter);
        Predictions.SubmitStatus[] memory statuses = predictions.submitForBatch(roundId, items);

        if (statuses[0] == Predictions.SubmitStatus.Ok) {
            storedPicks[roundId][user] = picks;
            storedConfirmedAt[roundId][user] = confirmedAt;
            ++accepted[roundId];
        }
    }

    function advance(uint32 dt) external {
        vm.warp(block.timestamp + (dt % 2 days));
    }

    /// The operator moves a game without a result anywhere from 1 day ago to 2 days ahead. Moves
    /// to the past, and any move of a game that has started, must be rejected (C1); a rejected
    /// call rolls back `lockedIn` too.
    function rescheduleGame(uint256 roundSeed, uint256 gameSeed, uint32 offset) external {
        bytes32 roundId = _round(roundSeed);
        bytes32 gameId = _games[roundId][gameSeed % GAMES];
        IResultsRegistry.Game memory g = registry.getGame(gameId);
        if (g.status != IResultsRegistry.GameStatus.Scheduled) return;
        uint64 lockTime = predictions.getRound(roundId).lockTime;
        if (block.timestamp >= lockTime && g.startTime >= lockTime) lockedIn[gameId] = true;
        vm.prank(operator);
        registry.rescheduleGame(gameId, uint64(block.timestamp) - 1 days + uint64(offset % 3 days));
    }

    /// The operator moves the lock of an open round to any future time not after its games, within
    /// MIN_LOCK_NOTICE (hence within MAX_CLOCK_SKEW, C5) too: those moves must be rejected.
    function updateRoundLock(uint256 roundSeed, uint32 offset) external {
        bytes32 roundId = _round(roundSeed);
        Predictions.Round memory r = predictions.getRound(roundId);
        if (r.state != Predictions.RoundState.Scheduled || block.timestamp >= r.lockTime) return;
        uint64 newLock = uint64(block.timestamp) + 1 + uint64(offset % 1 days);
        for (uint256 i = 0; i < GAMES; ++i) {
            uint64 startTime = registry.getGame(_games[roundId][i]).startTime;
            if (startTime < newLock) newLock = startTime;
        }
        if (newLock <= block.timestamp || newLock <= r.opensAt) return;
        vm.prank(operator);
        predictions.updateRoundLock(roundId, newLock);
    }

    /// The relayer records every game of a round that has tipped off (bit i of voidBits: void).
    function recordResults(uint256 roundSeed, uint8 winBits, uint8 voidBits) external {
        bytes32 roundId = _round(roundSeed);
        for (uint256 i = 0; i < GAMES; ++i) {
            bytes32 gameId = _games[roundId][i];
            IResultsRegistry.Game memory g = registry.getGame(gameId);
            if (g.status != IResultsRegistry.GameStatus.Scheduled || block.timestamp < g.startTime) continue;
            IResultsRegistry.ResultInput[] memory batch = new IResultsRegistry.ResultInput[](1);
            batch[0] = _input(gameId, g, (voidBits >> i) & 1 == 1, (winBits >> i) & 1 == 1);
            vm.prank(resultsRelayer);
            registry.recordResults(batch);
        }
    }

    /// The steward corrects a game while it can still be corrected: a void becomes a result, a
    /// result flips its winner or becomes a void.
    function correctResult(uint256 roundSeed, uint256 gameSeed, bool toVoid) external {
        bytes32 roundId = _round(roundSeed);
        bytes32 gameId = _games[roundId][gameSeed % GAMES];
        if (block.timestamp >= registry.correctableUntil(gameId)) return; // 0: no result or corrected
        IResultsRegistry.Game memory g = registry.getGame(gameId);
        bool isVoid = g.status == IResultsRegistry.GameStatus.Void ? false : toVoid;
        IResultsRegistry.ResultInput memory r = _input(gameId, g, isVoid, g.winner != IResultsRegistry.Side.Home);
        vm.prank(steward);
        registry.correctResult(r, "invariant");
    }

    /// The admin sets both windows anywhere in their ranges, in either order: a round must never
    /// settle while one of its results can still be corrected.
    function setWindows(uint32 delaySeed, uint32 windowSeed) external {
        vm.startPrank(admin);
        predictions.setFinalizationDelay(1 hours + uint64(delaySeed % (7 days - 1 hours + 1)));
        registry.setCorrectionWindow(1 hours + uint64(windowSeed % (7 days - 1 hours + 1)));
        vm.stopPrank();
    }

    /// Rare on purpose, so that most runs also reach finalization.
    function cancelRound(uint256 roundSeed, uint8 chance) external {
        if (chance % 8 != 0) return;
        bytes32 roundId = _round(roundSeed);
        if (predictions.getRound(roundId).state != Predictions.RoundState.Scheduled) return;
        vm.prank(steward);
        predictions.cancelRound(roundId, "invariant");
    }

    /// Anyone settles every round that is ready.
    function finalize() external {
        for (uint256 r = 0; r < roundIds.length; ++r) {
            bytes32 roundId = roundIds[r];
            uint64 readyAt = predictions.finalizableAt(roundId);
            if (readyAt == 0 || block.timestamp < readyAt) continue;
            predictions.finalizeRound(roundId);
            outcomesAtFinalization[roundId] = predictions.getRound(roundId).outcomes;
        }
    }

    function _round(uint256 seed) internal view returns (bytes32) {
        return roundIds[seed % roundIds.length];
    }

    function _input(
        bytes32 gameId,
        IResultsRegistry.Game memory g,
        bool isVoid,
        bool homeWins
    ) internal pure returns (IResultsRegistry.ResultInput memory) {
        return
            IResultsRegistry.ResultInput({
                gameId: gameId,
                homeTeam: g.homeTeam,
                awayTeam: g.awayTeam,
                status: isVoid ? IResultsRegistry.GameStatus.Void : IResultsRegistry.GameStatus.Final,
                winner: isVoid
                    ? IResultsRegistry.Side.None
                    : (homeWins ? IResultsRegistry.Side.Home : IResultsRegistry.Side.Away),
                homeScore: isVoid ? 0 : (homeWins ? 3 : 1), // volleyball sets
                awayScore: isVoid ? 0 : (homeWins ? 1 : 3),
                extraPeriods: 0,
                sourceHash: keccak256(abi.encode(gameId)),
                attestationId: "invariant"
            });
    }
}

contract PredictionsInvariantTest is M2Base {
    PredictionsHandler internal handler;

    function setUp() public override {
        super.setUp();
        _createLeague();
        bytes32[] memory roundIds = new bytes32[](3);
        bytes32[][] memory games = new bytes32[][](3);
        for (uint256 r = 0; r < 3; ++r) {
            uint64 lock = T0 + uint64(r + 1) * 1 days;
            games[r] = _registerGames(3, lock);
            roundIds[r] = _scheduleRound(uint16(r + 1), games[r], T0, lock);
        }
        handler = new PredictionsHandler(
            predictions,
            registry,
            [operator, submitter, resultsRelayer, steward, admin],
            roundIds,
            games
        );
        targetContract(address(handler));
        bytes4[] memory actions = new bytes4[](9);
        actions[0] = PredictionsHandler.submit.selector;
        actions[1] = PredictionsHandler.advance.selector;
        actions[2] = PredictionsHandler.rescheduleGame.selector;
        actions[3] = PredictionsHandler.updateRoundLock.selector;
        actions[4] = PredictionsHandler.recordResults.selector;
        actions[5] = PredictionsHandler.cancelRound.selector;
        actions[6] = PredictionsHandler.finalize.selector;
        actions[7] = PredictionsHandler.correctResult.selector;
        actions[8] = PredictionsHandler.setWindows.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions})); // not the getters
    }

    /// Stored predictions never change, match what was accepted, and stay before the round's lock
    /// even after the lock moved (the C5 property).
    function invariant_EntriesAreImmutable() public view {
        for (uint256 r = 0; r < handler.roundsLength(); ++r) {
            bytes32 roundId = handler.roundIds(r);
            uint64 lockTime = predictions.getRound(roundId).lockTime;
            for (uint256 i = 0; i < handler.usersLength(); ++i) {
                address user = handler.users(i);
                (uint64 confirmedAt, uint64 submittedAt, bytes memory picks) = predictions.getEntry(roundId, user);
                assertEq(picks, handler.storedPicks(roundId, user));
                assertEq(confirmedAt, handler.storedConfirmedAt(roundId, user));
                if (submittedAt != 0) {
                    assertLt(submittedAt, lockTime, "stored after lock");
                    assertLt(confirmedAt, lockTime, "confirmed after lock");
                }
            }
        }
    }

    /// One submission per user per round: each counter equals the accepted items.
    function invariant_OneSubmissionPerUser() public view {
        for (uint256 r = 0; r < handler.roundsLength(); ++r) {
            bytes32 roundId = handler.roundIds(r);
            assertEq(predictions.getRound(roundId).submissions, handler.accepted(roundId));
            assertLe(handler.accepted(roundId), handler.usersLength());
        }
    }

    /// Layer-0 scores are bounded.
    function invariant_ScoresAreBounded() public view {
        for (uint256 r = 0; r < handler.roundsLength(); ++r) {
            for (uint256 i = 0; i < handler.usersLength(); ++i) {
                (uint8 correct, uint8 counted) = predictions.scoreOf(handler.roundIds(r), handler.users(i));
                assertLe(correct, counted);
                assertLe(counted, 3);
            }
        }
    }

    /// leagueStatsOf never reverts, whatever moved, and its totals are consistent.
    function invariant_LeagueStatsAlwaysComputable() public view {
        for (uint256 i = 0; i < handler.usersLength(); ++i) {
            IPredictions.LeagueStats memory s = predictions.leagueStatsOf(LEAGUE, handler.users(i));
            assertEq(s.points, s.correct);
            assertLe(s.correct, s.counted);
            assertLe(s.roundsPlayed, handler.roundsLength());
        }
    }

    /// A finalized round's outcomes never change, and a game counts if and only if it was played
    /// or forfeited and started at or after the lock (the C1 property).
    function invariant_OnlyGamesStartedAfterTheLockCount() public view {
        for (uint256 r = 0; r < handler.roundsLength(); ++r) {
            bytes32 roundId = handler.roundIds(r);
            Predictions.Round memory round = predictions.getRound(roundId);
            if (round.state != Predictions.RoundState.Finalized) continue;
            assertEq(round.outcomes, handler.outcomesAtFinalization(roundId));
            for (uint256 i = 0; i < 3; ++i) {
                IResultsRegistry.Game memory g = registry.getGame(handler.gameOf(roundId, i));
                bool played = g.status == IResultsRegistry.GameStatus.Final ||
                    g.status == IResultsRegistry.GameStatus.Forfeit;
                bool counted = (round.outcomes >> (2 * i)) & 3 != 0;
                assertEq(counted, played && g.startTime >= round.lockTime);
                if (played && handler.lockedIn(handler.gameOf(roundId, i))) assertTrue(counted, "played after lock");
            }
        }
    }

    /// A finalized round's snapshot is exactly what the registry says today: no result of its
    /// games changed after it settled, so no correction ever came too late.
    function invariant_FinalizedRoundsMatchTheRegistry() public view {
        for (uint256 r = 0; r < handler.roundsLength(); ++r) {
            bytes32 roundId = handler.roundIds(r);
            Predictions.Round memory round = predictions.getRound(roundId);
            if (round.state != Predictions.RoundState.Finalized) continue;
            for (uint256 i = 0; i < 3; ++i) {
                bytes32 gameId = handler.gameOf(roundId, i);
                IResultsRegistry.Game memory g = registry.getGame(gameId);
                bool counts = (g.status == IResultsRegistry.GameStatus.Final ||
                    g.status == IResultsRegistry.GameStatus.Forfeit) && g.startTime >= round.lockTime;
                assertEq((round.outcomes >> (2 * i)) & 3, counts ? uint8(g.winner) : 0, "outcome changed after settling");
                assertEq(registry.correctableUntil(gameId) <= block.timestamp, true, "settled while correctable");
            }
        }
    }
}
