// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IPredictions} from "../contracts/interfaces/IPredictions.sol";
import {IResultsRegistry} from "../contracts/interfaces/IResultsRegistry.sol";
import {Predictions} from "../contracts/Predictions.sol";
import {ResultsRegistry} from "../contracts/ResultsRegistry.sol";
import {M2Base} from "./utils/M2Base.sol";

/// @dev Constructor, state-machine and pause guards not exercised by the flow-oriented suites.
contract GuardsTest is M2Base {
    function test_ConstructorGuards() public {
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.DelayOutOfRange.selector, uint64(1 hours)));
        new ResultsRegistry(0, admin, 1 hours, operator, resultsRelayer, steward);

        vm.expectRevert(ResultsRegistry.ZeroAddress.selector);
        new ResultsRegistry(0, admin, POSTPONE, address(0), resultsRelayer, steward);
        vm.expectRevert(ResultsRegistry.ZeroAddress.selector);
        new ResultsRegistry(0, admin, POSTPONE, operator, address(0), steward);
        vm.expectRevert(ResultsRegistry.ZeroAddress.selector);
        new ResultsRegistry(0, admin, POSTPONE, operator, resultsRelayer, address(0));

        uint64 delay = FINALIZATION_DELAY;
        vm.expectRevert(Predictions.ZeroAddress.selector);
        new Predictions(0, admin, ResultsRegistry(address(0)), operator, submitter, steward, delay);
        vm.expectRevert(Predictions.ZeroAddress.selector);
        new Predictions(0, admin, registry, address(0), submitter, steward, delay);
        vm.expectRevert(Predictions.ZeroAddress.selector);
        new Predictions(0, admin, registry, operator, address(0), steward, delay);
        vm.expectRevert(Predictions.ZeroAddress.selector);
        new Predictions(0, admin, registry, operator, submitter, address(0), delay);
        vm.expectRevert(abi.encodeWithSelector(Predictions.DelayOutOfRange.selector, uint64(59 minutes)));
        new Predictions(0, admin, registry, operator, submitter, steward, 59 minutes);
        vm.expectRevert(abi.encodeWithSelector(Predictions.DelayOutOfRange.selector, uint64(7 days + 1)));
        new Predictions(0, admin, registry, operator, submitter, steward, 7 days + 1);
    }

    function test_PredictionsConstructorGrantsRolesNotTheDeployer() public view {
        assertTrue(predictions.hasRole(predictions.OPERATOR_ROLE(), operator));
        assertTrue(predictions.hasRole(predictions.SUBMITTER_ROLE(), submitter));
        assertTrue(predictions.hasRole(predictions.STEWARD_ROLE(), steward));
        assertEq(predictions.defaultAdmin(), admin);
        assertEq(predictions.finalizationDelay(), FINALIZATION_DELAY);
        assertEq(address(predictions.registry()), address(registry));
        // This test contract deployed Predictions and holds nothing.
        assertFalse(predictions.hasRole(predictions.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(predictions.hasRole(predictions.OPERATOR_ROLE(), address(this)));
        assertFalse(predictions.hasRole(predictions.SUBMITTER_ROLE(), address(this)));
        assertFalse(predictions.hasRole(predictions.STEWARD_ROLE(), address(this)));
    }

    function test_CreateLeagueRejectsZeroId() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Predictions.InvalidLeague.selector, bytes32(0)));
        predictions.createLeague(bytes32(0), bytes32(0));
    }

    function test_LeagueRoundLimit() public {
        _createLeague();
        uint64 lock = T0 + 1 days;
        for (uint16 md = 1; md <= 64; ++md) {
            _scheduleRound(md, _registerGames(1, lock), T0, lock);
        }
        bytes32[] memory extra = _registerGames(1, lock);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Predictions.TooManyRounds.selector, LEAGUE));
        predictions.scheduleRound(LEAGUE, 65, T0, lock, extra);
    }

    function test_RoundStateGuards() public {
        _createLeague();
        uint64 lock = T0 + 1 days;
        bytes32[] memory games = _registerGames(1, lock);
        bytes32 roundId = _scheduleRound(1, games, T0, lock);

        vm.prank(steward);
        predictions.cancelRound(roundId, "cancelled");

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Predictions.RoundNotActive.selector, roundId));
        predictions.updateRoundLock(roundId, lock - 1 hours);

        vm.prank(steward);
        vm.expectRevert(abi.encodeWithSelector(Predictions.RoundNotActive.selector, roundId));
        predictions.cancelRound(roundId, "twice");
    }

    function test_LeagueFinalizationGuards() public {
        _createLeague();
        uint64 lock = T0 + 1 days;
        bytes32[] memory games = _registerGames(1, lock);
        bytes32 roundId = _scheduleRound(1, games, T0, lock);

        vm.warp(lock + 3 hours);
        _record(_final(games[0], true));
        _finalizeRound(roundId);

        bytes32 unknown = keccak256("nope");
        vm.startPrank(steward);
        vm.expectRevert(Predictions.InvalidStandings.selector);
        predictions.proposeStandings(LEAGUE, bytes32(0), 1, bytes32(0), "");
        vm.expectRevert(Predictions.InvalidStandings.selector);
        predictions.proposeStandings(LEAGUE, keccak256("root"), 0, bytes32(0), "");
        vm.expectRevert(abi.encodeWithSelector(Predictions.LeagueNotActive.selector, unknown));
        predictions.proposeStandings(unknown, keccak256("root"), 1, bytes32(0), "");
        vm.expectRevert(abi.encodeWithSelector(Predictions.LeagueNotActive.selector, unknown));
        predictions.finalizeLeague(unknown);
        vm.stopPrank();
    }

    function test_LeagueStatsSkipUnfinalizedRounds() public {
        _createLeague();
        uint64 lock = T0 + 1 days;
        bytes32 roundId = _scheduleRound(1, _registerGames(1, lock), T0, lock);
        vm.warp(T0 + 1 hours);
        _submit(aliceKey, alice, roundId, abi.encodePacked(uint8(1)));

        IPredictions.LeagueStats memory s = predictions.leagueStatsOf(LEAGUE, alice);
        assertEq(s.roundsPlayed, 0);
        assertEq(s.counted, 0);
    }

    function test_RescheduleRejectsZeroStartTime() public {
        bytes32 game = _registerGames(1, T0 + 1 days)[0];
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.StartTimeInPast.selector, game, uint64(0)));
        registry.rescheduleGame(game, 0);
    }

    function test_PauseAndUnpause() public {
        bytes32 stewardRole = predictions.STEWARD_ROLE();
        bytes32 adminRole = predictions.DEFAULT_ADMIN_ROLE();
        address[3] memory others = [operator, submitter, stranger];
        for (uint256 i = 0; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, others[i], stewardRole)
            );
            predictions.pause();
        }

        vm.startPrank(steward);
        registry.pause();
        predictions.pause();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, steward, adminRole)
        );
        predictions.unpause();
        vm.stopPrank();

        vm.prank(operator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        predictions.createLeague(LEAGUE, bytes32(0));

        vm.startPrank(admin);
        registry.unpause();
        predictions.unpause();
        vm.stopPrank();
        _createLeague();
    }

    /// While paused only cancelRound, the admin functions and the reads work.
    function test_PauseStopsEverythingButCancelRound() public {
        _createLeague();
        uint64 lock = T0 + 1 days;
        bytes32[] memory games = _registerGames(1, lock);
        bytes32 roundId = _scheduleRound(1, games, T0, lock);
        Predictions.BatchItem[] memory items = new Predictions.BatchItem[](1);
        items[0] = _item(aliceKey, alice, roundId, abi.encodePacked(uint8(1)), uint64(block.timestamp));
        Predictions.BatchItem memory it = items[0];

        vm.prank(steward);
        predictions.pause();

        vm.startPrank(operator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        predictions.createLeague(keccak256("other"), bytes32(0));
        vm.expectRevert(Pausable.EnforcedPause.selector);
        predictions.scheduleRound(LEAGUE, 2, T0, lock, games);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        predictions.updateRoundLock(roundId, lock - 1 hours);
        vm.stopPrank();

        vm.startPrank(submitter);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        predictions.submitFor(it.user, roundId, it.picksHash, it.picks, it.confirmedAt, it.signature);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        predictions.submitForBatch(roundId, items);
        vm.stopPrank();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        predictions.finalizeRound(roundId);

        vm.startPrank(steward);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        predictions.proposeStandings(LEAGUE, keccak256("root"), 1, bytes32(0), "");
        vm.expectRevert(Pausable.EnforcedPause.selector);
        predictions.finalizeLeague(LEAGUE);
        vm.stopPrank();

        // The remedy still works: the steward cancels the round, the admin manages roles and parameters.
        vm.prank(steward);
        predictions.cancelRound(roundId, "wrong result");
        vm.startPrank(admin);
        predictions.revokeRole(predictions.SUBMITTER_ROLE(), submitter);
        predictions.setFinalizationDelay(2 hours);
        vm.stopPrank();
        assertEq(uint8(predictions.getRound(roundId).state), uint8(Predictions.RoundState.Cancelled));
        assertFalse(predictions.hasRole(predictions.SUBMITTER_ROLE(), submitter));
        assertEq(predictions.finalizationDelay(), 2 hours);
    }

    function test_GameViewsForUnknownGame() public view {
        (IResultsRegistry.GameStatus status, , uint64 startTime, uint64 recordedAt) = registry.outcomeOf(keccak256("x"));
        assertEq(uint8(status), uint8(IResultsRegistry.GameStatus.None));
        assertEq(startTime, 0);
        assertEq(recordedAt, 0);
    }
}
