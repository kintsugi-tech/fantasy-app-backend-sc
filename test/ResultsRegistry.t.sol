// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IResultsRegistry} from "../contracts/interfaces/IResultsRegistry.sol";
import {ResultsRegistry} from "../contracts/ResultsRegistry.sol";
import {M2Base} from "./utils/M2Base.sol";

contract ResultsRegistryTest is M2Base {
    bytes32 internal game;
    uint64 internal startTime;

    function setUp() public override {
        super.setUp();
        startTime = T0 + 1 days;
        game = _registerGames(1, startTime)[0];
    }

    // --- registerGames ---------------------------------------------------------

    function test_RegisterStoresFixture() public view {
        IResultsRegistry.Game memory g = registry.getGame(game);
        assertEq(uint8(g.status), uint8(IResultsRegistry.GameStatus.Scheduled));
        assertEq(g.homeTeam, _homeTeam(1));
        assertEq(g.awayTeam, _awayTeam(1));
        assertEq(g.startTime, startTime);
        assertEq(g.targetScore, VOLLEYBALL_SETS);
        assertFalse(g.drawAllowed);
        assertEq(g.recordedAt, 0);
        assertFalse(registry.isFinal(game));
    }

    /// Each game keeps its own format: volleyball, or an open score with draws for a sport that has them.
    function test_RegisterStoresFormat() public {
        IResultsRegistry.GameInfo[] memory infos = new IResultsRegistry.GameInfo[](2);
        infos[0] = IResultsRegistry.GameInfo(_gameId(901), _homeTeam(901), _awayTeam(901), startTime, VOLLEYBALL_SETS, false);
        infos[1] = IResultsRegistry.GameInfo(_gameId(902), _homeTeam(902), _awayTeam(902), startTime, 0, true);
        vm.expectEmit(address(registry));
        emit ResultsRegistry.GameRegistered(_gameId(901), _homeTeam(901), _awayTeam(901), startTime, VOLLEYBALL_SETS, false);
        vm.prank(operator);
        registry.registerGames(infos);

        IResultsRegistry.Game memory volleyball = registry.getGame(_gameId(901));
        assertEq(volleyball.targetScore, VOLLEYBALL_SETS);
        assertFalse(volleyball.drawAllowed);
        IResultsRegistry.Game memory openWithDraws = registry.getGame(_gameId(902));
        assertEq(openWithDraws.targetScore, 0);
        assertTrue(openWithDraws.drawAllowed);
    }

    function test_RegisterIsWriteOnce() public {
        IResultsRegistry.GameInfo[] memory infos = new IResultsRegistry.GameInfo[](1);
        infos[0] = IResultsRegistry.GameInfo(game, _homeTeam(9), _awayTeam(9), startTime, VOLLEYBALL_SETS, false);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.GameAlreadyRegistered.selector, game));
        registry.registerGames(infos);
    }

    function test_RegisterRejectsInvalidInfo() public {
        IResultsRegistry.GameInfo[] memory infos = new IResultsRegistry.GameInfo[](1);
        bytes32 id = _gameId(999);

        infos[0] = IResultsRegistry.GameInfo(id, _homeTeam(1), _homeTeam(1), startTime, VOLLEYBALL_SETS, false); // same teams
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.InvalidGameInfo.selector, id));
        registry.registerGames(infos);

        infos[0] = IResultsRegistry.GameInfo(id, _homeTeam(1), _awayTeam(1), 0, VOLLEYBALL_SETS, false); // no start time
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.InvalidGameInfo.selector, id));
        registry.registerGames(infos);

        infos[0] = IResultsRegistry.GameInfo(bytes32(0), _homeTeam(1), _awayTeam(1), startTime, VOLLEYBALL_SETS, false);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.InvalidGameInfo.selector, bytes32(0)));
        registry.registerGames(infos);

        // A race to N sets cannot end in a draw.
        infos[0] = IResultsRegistry.GameInfo(id, _homeTeam(1), _awayTeam(1), startTime, VOLLEYBALL_SETS, true);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.InvalidGameInfo.selector, id));
        registry.registerGames(infos);
    }

    function test_RegisterBatchBounds() public {
        vm.prank(operator);
        vm.expectRevert(ResultsRegistry.EmptyBatch.selector);
        registry.registerGames(new IResultsRegistry.GameInfo[](0));

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.BatchTooLarge.selector, 101, 100));
        registry.registerGames(new IResultsRegistry.GameInfo[](101));
    }

    function test_RegisterOnlyOperator() public {
        bytes32 role = registry.OPERATOR_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        registry.registerGames(new IResultsRegistry.GameInfo[](1));
    }

    function test_ConstructorGrantsRolesNotTheDeployer() public view {
        assertTrue(registry.hasRole(registry.OPERATOR_ROLE(), operator));
        assertTrue(registry.hasRole(registry.RESULTS_RELAYER_ROLE(), resultsRelayer));
        assertTrue(registry.hasRole(registry.STEWARD_ROLE(), steward));
        assertEq(registry.defaultAdmin(), admin);
        // This test contract deployed the registry and holds nothing.
        assertFalse(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(registry.hasRole(registry.OPERATOR_ROLE(), address(this)));
        assertFalse(registry.hasRole(registry.RESULTS_RELAYER_ROLE(), address(this)));
        assertFalse(registry.hasRole(registry.STEWARD_ROLE(), address(this)));
    }

    function test_RescheduleRejectsPastStartTime() public {
        vm.warp(T0 + 1 hours);
        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.StartTimeInPast.selector, game, uint64(T0)));
        registry.rescheduleGame(game, T0);
        vm.expectRevert(
            abi.encodeWithSelector(ResultsRegistry.StartTimeInPast.selector, game, uint64(block.timestamp))
        );
        registry.rescheduleGame(game, uint64(block.timestamp));
        registry.rescheduleGame(game, uint64(block.timestamp) + 1);
        vm.stopPrank();
        assertEq(registry.getGame(game).startTime, block.timestamp + 1);
    }

    function test_RescheduleOnlyWithoutResult() public {
        vm.prank(operator);
        registry.rescheduleGame(game, startTime + 1 hours);
        assertEq(registry.getGame(game).startTime, startTime + 1 hours);

        vm.warp(startTime + 3 hours);
        _record(_final(game, true));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.GameNotScheduled.selector, game));
        registry.rescheduleGame(game, startTime + 5 hours);
    }

    /// The start is the boundary: until then the game moves and takes no result; from then on its
    /// start time is fixed and it takes a result (or a void).
    function test_RescheduleOnlyBeforeTheStart() public {
        vm.warp(startTime - 1);
        vm.prank(operator);
        registry.rescheduleGame(game, startTime + 1 days);

        vm.warp(startTime + 1 days);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.GameAlreadyStarted.selector, game, startTime + 1 days));
        registry.rescheduleGame(game, startTime + 2 days);
        _record(_final(game, true)); // a result is accepted from the same instant
    }

    /// A game postponed after its start keeps its start time, so the registry accepts a void at
    /// once; past the correction window the replay can no longer be recorded. The worker must not
    /// record a void for a game that is only postponed.
    function test_EarlyVoidOfAPostponedGameIsFinal() public {
        vm.warp(startTime + 2 hours);
        _record(_result(game, IResultsRegistry.GameStatus.Void, IResultsRegistry.Side.None, 0, 0));
        uint64 until = registry.correctableUntil(game);

        vm.warp(startTime + 3 days);
        IResultsRegistry.ResultInput memory replay = _final(game, true);
        vm.prank(steward);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.CorrectionWindowClosed.selector, game, until));
        registry.correctResult(replay, "replay");

        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.ResultAlreadyRecorded.selector, game));
        this.recordAsRelayer(replay);
    }

    // --- recordResults ---------------------------------------------------------

    function test_RecordFinalResult() public {
        vm.warp(startTime + 2 hours);
        IResultsRegistry.ResultInput memory r = _final(game, false);
        vm.expectEmit(address(registry));
        emit ResultsRegistry.ResultRecorded(
            game,
            IResultsRegistry.GameStatus.Final,
            IResultsRegistry.Side.Away,
            0,
            3,
            0,
            r.sourceHash,
            r.attestationId
        );
        _record(r);

        IResultsRegistry.Game memory g = registry.getGame(game);
        assertEq(uint8(g.status), uint8(IResultsRegistry.GameStatus.Final));
        assertEq(uint8(g.winner), uint8(IResultsRegistry.Side.Away));
        assertEq(g.sourceHash, r.sourceHash);
        assertEq(g.recordedAt, block.timestamp);
        assertTrue(registry.isFinal(game)); // final as soon as it is written
    }

    /// Extra periods exist only in open-score formats (never in volleyball, see below).
    function test_RecordExtraPeriods() public {
        bytes32 open = _registerGames(1, startTime, 0, false)[0];
        vm.warp(startTime + 3 hours);
        IResultsRegistry.ResultInput memory r = _final(open, true);
        r.extraPeriods = 2;
        _record(r);
        assertEq(registry.getGame(open).extraPeriods, 2);
    }

    function test_RecordRejectsResultBeforeStart() public {
        IResultsRegistry.ResultInput memory played = _final(game, true);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.BeforeStart.selector, game));
        this.recordAsRelayer(played);

        IResultsRegistry.ResultInput memory forfeit = _result(
            game,
            IResultsRegistry.GameStatus.Forfeit,
            IResultsRegistry.Side.Home,
            3,
            0
        );
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.BeforeStart.selector, game));
        this.recordAsRelayer(forfeit);
    }

    function test_RecordVoidOnlyFromStart() public {
        IResultsRegistry.ResultInput memory void_ = _result(
            game,
            IResultsRegistry.GameStatus.Void,
            IResultsRegistry.Side.None,
            0,
            0
        );
        vm.warp(startTime - 1);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.BeforeStart.selector, game));
        this.recordAsRelayer(void_);

        vm.warp(startTime);
        _record(void_);
        assertEq(uint8(registry.getGame(game).status), uint8(IResultsRegistry.GameStatus.Void));
    }

    function test_RecordRejectsSwappedTeams() public {
        vm.warp(startTime + 2 hours);
        IResultsRegistry.ResultInput memory r = _final(game, true);
        (r.homeTeam, r.awayTeam) = (r.awayTeam, r.homeTeam);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.TeamsMismatch.selector, game));
        this.recordAsRelayer(r);
    }

    function test_RecordRejectsInconsistentResults() public {
        vm.warp(startTime + 2 hours);
        IResultsRegistry.ResultInput memory r;

        r = _result(game, IResultsRegistry.GameStatus.Final, IResultsRegistry.Side.Home, 3, 3); // level
        _expectInvalid(r);
        r = _result(game, IResultsRegistry.GameStatus.Final, IResultsRegistry.Side.Draw, 3, 3); // no draws here
        _expectInvalid(r);
        r = _result(game, IResultsRegistry.GameStatus.Final, IResultsRegistry.Side.Home, 1, 3); // wrong winner
        _expectInvalid(r);
        r = _result(game, IResultsRegistry.GameStatus.Final, IResultsRegistry.Side.None, 3, 1);
        _expectInvalid(r);
        r = _result(game, IResultsRegistry.GameStatus.Final, IResultsRegistry.Side.Draw, 3, 1);
        _expectInvalid(r);
        r = _result(game, IResultsRegistry.GameStatus.Forfeit, IResultsRegistry.Side.None, 0, 0);
        _expectInvalid(r);
        r = _result(game, IResultsRegistry.GameStatus.Forfeit, IResultsRegistry.Side.Draw, 0, 0);
        _expectInvalid(r);
        // A forfeit has a winner: Draw must not pass as Away when Away is ahead.
        r = _result(game, IResultsRegistry.GameStatus.Forfeit, IResultsRegistry.Side.Draw, 0, 3);
        _expectInvalid(r);
        r = _result(game, IResultsRegistry.GameStatus.Forfeit, IResultsRegistry.Side.Away, 3, 0);
        _expectInvalid(r);
        r = _result(game, IResultsRegistry.GameStatus.Forfeit, IResultsRegistry.Side.Home, 3, 0);
        r.extraPeriods = 1;
        _expectInvalid(r);
        r = _result(game, IResultsRegistry.GameStatus.Void, IResultsRegistry.Side.Home, 0, 0);
        _expectInvalid(r);
        r = _result(game, IResultsRegistry.GameStatus.Void, IResultsRegistry.Side.None, 1, 0);
        _expectInvalid(r);
        r = _result(game, IResultsRegistry.GameStatus.Scheduled, IResultsRegistry.Side.Home, 3, 1);
        _expectInvalid(r);
    }

    function test_RecordForfeitWithoutScore() public {
        vm.warp(startTime);
        _record(_result(game, IResultsRegistry.GameStatus.Forfeit, IResultsRegistry.Side.Away, 0, 0));
        assertEq(uint8(registry.getGame(game).winner), uint8(IResultsRegistry.Side.Away));
    }

    // --- formats ---------------------------------------------------------------

    /// Volleyball (best of 5): the scores are sets and the winner has exactly 3.
    function test_VolleyballResults() public {
        bytes32[] memory ids = _registerGames(5, startTime);
        vm.warp(startTime + 2 hours);
        _record(_result(ids[0], IResultsRegistry.GameStatus.Final, IResultsRegistry.Side.Home, 3, 0));
        _record(_result(ids[1], IResultsRegistry.GameStatus.Final, IResultsRegistry.Side.Away, 1, 3));
        _record(_result(ids[2], IResultsRegistry.GameStatus.Final, IResultsRegistry.Side.Home, 3, 2));
        _record(_result(ids[3], IResultsRegistry.GameStatus.Forfeit, IResultsRegistry.Side.Home, 3, 0));
        _record(_result(ids[4], IResultsRegistry.GameStatus.Forfeit, IResultsRegistry.Side.Away, 0, 0));
        IResultsRegistry.Game memory g = registry.getGame(ids[2]);
        assertEq(uint8(g.winner), uint8(IResultsRegistry.Side.Home));
        assertEq(g.homeScore, 3);
        assertEq(g.awayScore, 2);
    }

    function test_VolleyballRejectsUnfinishedOrImpossibleScores() public {
        vm.warp(startTime + 2 hours);
        IResultsRegistry.ResultInput memory r;

        r = _result(game, IResultsRegistry.GameStatus.Final, IResultsRegistry.Side.Home, 2, 1); // not over
        _expectInvalid(r);
        r = _result(game, IResultsRegistry.GameStatus.Final, IResultsRegistry.Side.Home, 4, 1); // past the target
        _expectInvalid(r);
        r = _result(game, IResultsRegistry.GameStatus.Final, IResultsRegistry.Side.Home, 3, 1);
        r.extraPeriods = 1; // a fifth set is a set, not an extra period
        _expectInvalid(r);
        r = _result(game, IResultsRegistry.GameStatus.Forfeit, IResultsRegistry.Side.Home, 4, 0);
        _expectInvalid(r);

        _record(_result(game, IResultsRegistry.GameStatus.Final, IResultsRegistry.Side.Home, 3, 1));
        assertTrue(registry.isFinal(game));
    }

    /// Formats a sport other than volleyball may need, with no contract change: an open score (the
    /// side ahead wins), with or without draws.
    function test_OpenScoreFormats() public {
        bytes32 open = _registerGames(1, startTime, 0, false)[0];
        bytes32[] memory withDraws = _registerGames(3, startTime, 0, true);
        vm.warp(startTime + 2 hours);
        IResultsRegistry.ResultInput memory r;

        r = _result(open, IResultsRegistry.GameStatus.Final, IResultsRegistry.Side.Home, 80, 80);
        _expectInvalid(r);
        r = _result(open, IResultsRegistry.GameStatus.Final, IResultsRegistry.Side.Draw, 80, 80);
        _expectInvalid(r);
        r = _result(withDraws[0], IResultsRegistry.GameStatus.Final, IResultsRegistry.Side.Home, 1, 1);
        _expectInvalid(r);
        r = _result(withDraws[0], IResultsRegistry.GameStatus.Final, IResultsRegistry.Side.None, 1, 1);
        _expectInvalid(r);
        r = _result(withDraws[0], IResultsRegistry.GameStatus.Final, IResultsRegistry.Side.Draw, 2, 1);
        _expectInvalid(r);
        r = _result(withDraws[0], IResultsRegistry.GameStatus.Forfeit, IResultsRegistry.Side.Draw, 0, 0);
        _expectInvalid(r);

        _record(_result(open, IResultsRegistry.GameStatus.Forfeit, IResultsRegistry.Side.Away, 0, 20));
        _record(_draw(withDraws[0]));
        _record(_result(withDraws[1], IResultsRegistry.GameStatus.Final, IResultsRegistry.Side.Draw, 0, 0));
        _record(_result(withDraws[2], IResultsRegistry.GameStatus.Final, IResultsRegistry.Side.Home, 2, 1));
        (IResultsRegistry.GameStatus status, IResultsRegistry.Side winner, , ) = registry.outcomeOf(withDraws[0]);
        assertEq(uint8(status), uint8(IResultsRegistry.GameStatus.Final));
        assertEq(uint8(winner), uint8(IResultsRegistry.Side.Draw));
    }

    function test_RecordRejectsMissingSource() public {
        vm.warp(startTime + 2 hours);
        IResultsRegistry.ResultInput memory r = _final(game, true);
        r.sourceHash = bytes32(0);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.InvalidSource.selector, game));
        this.recordAsRelayer(r);

        r = _final(game, true);
        r.attestationId = "";
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.InvalidSource.selector, game));
        this.recordAsRelayer(r);
    }

    function test_RecordIsWriteOnce() public {
        vm.warp(startTime + 2 hours);
        _record(_final(game, true));
        vm.warp(block.timestamp + 30 days);
        IResultsRegistry.ResultInput memory again = _final(game, false);
        again.attestationId = "mvl_2026_game-0001-v2";
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.ResultAlreadyRecorded.selector, game));
        this.recordAsRelayer(again);
        assertEq(uint8(registry.getGame(game).winner), uint8(IResultsRegistry.Side.Home));
    }

    function test_RecordRejectsUnknownGame() public {
        vm.warp(startTime + 2 hours);
        IResultsRegistry.ResultInput memory r = _final(game, true);
        r.gameId = _gameId(777);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.GameNotScheduled.selector, r.gameId));
        this.recordAsRelayer(r);
    }

    function test_RecordOnlyRelayerAndNotPaused() public {
        vm.warp(startTime + 2 hours);
        IResultsRegistry.ResultInput[] memory batch = new IResultsRegistry.ResultInput[](1);
        batch[0] = _final(game, true);
        bytes32 role = registry.RESULTS_RELAYER_ROLE();

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, role)
        );
        registry.recordResults(batch);

        vm.prank(steward);
        registry.pause();
        vm.prank(resultsRelayer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.recordResults(batch);
    }

    // --- pause -----------------------------------------------------------------

    function test_StewardPausesOnlyAdminUnpauses() public {
        bytes32 stewardRole = registry.STEWARD_ROLE();
        bytes32 adminRole = registry.DEFAULT_ADMIN_ROLE();
        address[3] memory others = [operator, resultsRelayer, stranger];
        for (uint256 i = 0; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, others[i], stewardRole)
            );
            registry.pause();
        }

        vm.prank(steward);
        registry.pause();
        assertTrue(registry.paused());

        vm.prank(steward);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, steward, adminRole)
        );
        registry.unpause();

        vm.prank(admin);
        registry.unpause();
        assertFalse(registry.paused());
    }

    /// Every write stops; the admin can still manage roles and parameters, and reads work.
    function test_PauseStopsEveryWrite() public {
        vm.prank(steward);
        registry.pause();

        vm.prank(operator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.registerGames(new IResultsRegistry.GameInfo[](1));

        vm.prank(operator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.rescheduleGame(game, startTime + 1 hours);

        vm.warp(startTime + POSTPONE + 1);
        IResultsRegistry.ResultInput memory r = _final(game, true);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        this.recordAsRelayer(r);

        vm.prank(steward);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.voidGame(game, "paused");

        vm.startPrank(admin);
        registry.revokeRole(registry.RESULTS_RELAYER_ROLE(), resultsRelayer);
        registry.setPostponeWindow(2 days);
        vm.stopPrank();
        assertFalse(registry.hasRole(registry.RESULTS_RELAYER_ROLE(), resultsRelayer));
        assertEq(registry.getGame(game).startTime, startTime);
        assertFalse(registry.isFinal(game));
    }

    // --- voidGame --------------------------------------------------------------

    function test_VoidAfterPostponeWindow() public {
        uint64 voidableAt = startTime + POSTPONE;
        vm.warp(voidableAt);
        vm.prank(steward);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.PostponeWindowOpen.selector, game, voidableAt));
        registry.voidGame(game, "postponed");

        vm.warp(voidableAt + 1);
        vm.prank(steward);
        registry.voidGame(game, "postponed indefinitely");
        IResultsRegistry.Game memory g = registry.getGame(game);
        assertEq(uint8(g.status), uint8(IResultsRegistry.GameStatus.Void));
        assertTrue(registry.isFinal(game));
    }

    function test_VoidOnlySteward() public {
        vm.warp(startTime + POSTPONE + 1);
        bytes32 role = registry.STEWARD_ROLE();
        vm.prank(resultsRelayer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, resultsRelayer, role)
        );
        registry.voidGame(game, "relayer cannot void");
    }

    function test_VoidRejectedWhenResultExists() public {
        vm.warp(startTime + 2 hours);
        _record(_final(game, true));
        vm.warp(startTime + POSTPONE + 1);
        vm.prank(steward);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.GameNotScheduled.selector, game));
        registry.voidGame(game, "has a result");
    }

    // --- correctResult ---------------------------------------------------------

    /// A parser bug is corrected from the same attested file: same source, right result.
    function test_CorrectResult() public {
        vm.warp(startTime + 2 hours);
        IResultsRegistry.ResultInput memory wrong = _final(game, true);
        _record(wrong);
        assertEq(registry.correctableUntil(game), startTime + 2 hours + CORRECTION_WINDOW);

        vm.warp(startTime + 3 hours);
        IResultsRegistry.ResultInput memory right = _final(game, false);
        right.sourceHash = wrong.sourceHash;
        vm.expectEmit(address(registry));
        emit ResultsRegistry.ResultCorrected(
            game,
            IResultsRegistry.GameStatus.Final,
            IResultsRegistry.Side.Away,
            0,
            VOLLEYBALL_SETS,
            0,
            wrong.sourceHash,
            right.attestationId,
            "home and away swapped by the parser"
        );
        vm.prank(steward);
        registry.correctResult(right, "home and away swapped by the parser");

        IResultsRegistry.Game memory g = registry.getGame(game);
        assertEq(uint8(g.status), uint8(IResultsRegistry.GameStatus.Final));
        assertEq(uint8(g.winner), uint8(IResultsRegistry.Side.Away));
        assertEq(g.homeScore, 0);
        assertEq(g.awayScore, VOLLEYBALL_SETS);
        assertEq(g.recordedAt, startTime + 3 hours);
        assertTrue(g.corrected);
        assertEq(g.correctableUntil, 0);
        assertTrue(registry.isFinal(game));
        assertEq(registry.correctableUntil(game), 0); // can never change again
    }

    function test_CorrectableUntilWithoutResult() public view {
        assertEq(registry.correctableUntil(game), 0);
        assertEq(registry.correctableUntil(keccak256("unknown")), 0);
    }

    /// The deadline is fixed with the result: widening the window later never reopens it (a round
    /// already settled on that result must not see it change), narrowing it never cuts it short.
    function test_WindowChangeAppliesToLaterResults() public {
        vm.warp(startTime + 2 hours);
        _record(_final(game, true));
        uint64 deadline = startTime + 2 hours + CORRECTION_WINDOW;
        vm.prank(admin);
        registry.setCorrectionWindow(7 days);
        assertEq(registry.correctableUntil(game), deadline);

        IResultsRegistry.ResultInput memory r = _final(game, false);
        vm.warp(deadline);
        vm.prank(steward);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.CorrectionWindowClosed.selector, game, deadline));
        registry.correctResult(r, "reopened?");

        bytes32 later = _registerGames(1, uint64(block.timestamp) + 1 hours)[0];
        vm.warp(block.timestamp + 2 hours);
        _record(_final(later, true));
        assertEq(registry.correctableUntil(later), block.timestamp + 7 days);
    }

    function test_VoidOpensTheCorrectionWindow() public {
        vm.warp(startTime + POSTPONE + 1);
        vm.prank(steward);
        registry.voidGame(game, "no result");
        assertEq(registry.correctableUntil(game), block.timestamp + CORRECTION_WINDOW);
    }

    function test_CorrectOnlySteward() public {
        vm.warp(startTime + 2 hours);
        _record(_final(game, true));
        bytes32 role = registry.STEWARD_ROLE();
        IResultsRegistry.ResultInput memory r = _final(game, false);
        address[3] memory others = [resultsRelayer, operator, admin];
        for (uint256 i = 0; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, others[i], role));
            registry.correctResult(r, "not mine");
        }
    }

    function test_CorrectNeedsAResult() public {
        IResultsRegistry.ResultInput memory r = _final(game, false);
        vm.prank(steward);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.NoResult.selector, game));
        registry.correctResult(r, "no result yet");
    }

    function test_CorrectOnlyWithinTheWindow() public {
        vm.warp(startTime + 2 hours);
        _record(_final(game, true));
        uint64 deadline = startTime + 2 hours + CORRECTION_WINDOW;
        IResultsRegistry.ResultInput memory r = _final(game, false);
        vm.warp(deadline);
        vm.prank(steward);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.CorrectionWindowClosed.selector, game, deadline));
        registry.correctResult(r, "too late");
    }

    /// One correction: if it is wrong too, cancelling the round is what remains.
    function test_CorrectOnlyOnce() public {
        vm.warp(startTime + 2 hours);
        IResultsRegistry.ResultInput memory first = _final(game, true);
        IResultsRegistry.ResultInput memory second = _final(game, false);
        _record(first);
        vm.startPrank(steward);
        registry.correctResult(second, "first");
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.AlreadyCorrected.selector, game));
        registry.correctResult(first, "second");
        vm.stopPrank();
    }

    function test_CorrectRunsTheRecordChecks() public {
        vm.warp(startTime + 2 hours);
        _record(_final(game, true));
        IResultsRegistry.ResultInput memory swapped = _final(game, false);
        (swapped.homeTeam, swapped.awayTeam) = (swapped.awayTeam, swapped.homeTeam);
        // not a race to 3
        IResultsRegistry.ResultInput memory unfinished = _result(
            game,
            IResultsRegistry.GameStatus.Final,
            IResultsRegistry.Side.Home,
            2,
            1
        );
        IResultsRegistry.ResultInput memory noSource = _final(game, false);
        noSource.sourceHash = bytes32(0);

        vm.startPrank(steward);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.TeamsMismatch.selector, game));
        registry.correctResult(swapped, "swapped teams");
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.InvalidResult.selector, game));
        registry.correctResult(unfinished, "unfinished");
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.InvalidSource.selector, game));
        registry.correctResult(noSource, "no source");
        vm.stopPrank();

        assertFalse(registry.getGame(game).corrected); // nothing written
    }

    /// A game voided by the steward (no result in time) is corrected once its result turns up.
    function test_CorrectAVoidedGame() public {
        IResultsRegistry.ResultInput memory r = _final(game, true);
        vm.warp(startTime + POSTPONE + 1);
        vm.startPrank(steward);
        registry.voidGame(game, "no result");
        registry.correctResult(r, "the result turned up");
        vm.stopPrank();
        assertEq(uint8(registry.getGame(game).status), uint8(IResultsRegistry.GameStatus.Final));
    }

    /// The remedy works while paused (e.g. the relayer is stopped) and the relayer can never
    /// write over a correction.
    function test_CorrectWhilePausedAndRelayerCannotOverwrite() public {
        vm.warp(startTime + 2 hours);
        IResultsRegistry.ResultInput memory first = _final(game, true);
        IResultsRegistry.ResultInput memory right = _final(game, false);
        _record(first);
        vm.startPrank(steward);
        registry.pause();
        registry.correctResult(right, "while paused");
        vm.stopPrank();
        vm.prank(admin);
        registry.unpause();

        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.ResultAlreadyRecorded.selector, game));
        this.recordAsRelayer(first);
    }

    // --- admin -----------------------------------------------------------------

    function test_AdminParameterBounds() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.DelayOutOfRange.selector, uint64(1 hours)));
        registry.setPostponeWindow(1 hours);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.DelayOutOfRange.selector, uint64(31 days)));
        registry.setPostponeWindow(31 days);
        registry.setPostponeWindow(2 days);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.DelayOutOfRange.selector, uint64(1 hours - 1)));
        registry.setCorrectionWindow(1 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.DelayOutOfRange.selector, uint64(7 days + 1)));
        registry.setCorrectionWindow(7 days + 1);
        vm.expectEmit(address(registry));
        emit ResultsRegistry.CorrectionWindowSet(2 hours);
        registry.setCorrectionWindow(2 hours);
        vm.stopPrank();
        assertEq(registry.postponeWindow(), 2 days);
        assertEq(registry.correctionWindow(), 2 hours);

        bytes32 role = registry.DEFAULT_ADMIN_ROLE();
        vm.prank(steward);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, steward, role));
        registry.setCorrectionWindow(3 hours);
    }

    // --- helpers ---------------------------------------------------------------

    /// @dev External hop so vm.expectRevert can target a call that is not the prank itself.
    function recordAsRelayer(IResultsRegistry.ResultInput calldata r) external {
        IResultsRegistry.ResultInput[] memory batch = new IResultsRegistry.ResultInput[](1);
        batch[0] = r;
        vm.prank(resultsRelayer);
        registry.recordResults(batch);
    }

    function _expectInvalid(IResultsRegistry.ResultInput memory r) internal {
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.InvalidResult.selector, r.gameId));
        this.recordAsRelayer(r);
    }
}
