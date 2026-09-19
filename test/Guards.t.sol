// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IPredictions} from "../contracts/interfaces/IPredictions.sol";
import {IResultsRegistry} from "../contracts/interfaces/IResultsRegistry.sol";
import {LeagueBadge} from "../contracts/LeagueBadge.sol";
import {Predictions} from "../contracts/Predictions.sol";
import {ResultsRegistry} from "../contracts/ResultsRegistry.sol";
import {M2Base} from "./utils/M2Base.sol";

/// @dev Constructor, state-machine and pause guards not exercised by the flow-oriented suites.
contract GuardsTest is M2Base {
    function test_ConstructorGuards() public {
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.DelayOutOfRange.selector, uint64(73 hours)));
        new ResultsRegistry(0, admin, 73 hours, POSTPONE);

        vm.expectRevert(Predictions.ZeroAddress.selector);
        new Predictions(0, admin, ResultsRegistry(address(0)), CHALLENGE);

        vm.expectRevert(abi.encodeWithSelector(Predictions.WindowOutOfRange.selector, uint64(8 days)));
        new Predictions(0, admin, registry, 8 days);

        vm.expectRevert(LeagueBadge.ZeroAddress.selector);
        new LeagueBadge(0, admin, IPredictions(address(0)));
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

        vm.prank(steward);
        vm.expectRevert(abi.encodeWithSelector(Predictions.LeagueNotActive.selector, LEAGUE));
        predictions.replaceStandings(LEAGUE, keccak256("root"), 1, bytes32(0), "");

        vm.warp(lock + 3 hours);
        _record(_final(games[0], true));
        vm.warp(block.timestamp + FINALITY);
        predictions.finalizeRound(roundId);

        vm.startPrank(steward);
        predictions.finalizeLeague(LEAGUE, keccak256("root"), 1, bytes32(0), "");
        vm.expectRevert(abi.encodeWithSelector(Predictions.LeagueNotActive.selector, LEAGUE));
        predictions.finalizeLeague(LEAGUE, keccak256("root"), 1, bytes32(0), "");
        vm.expectRevert(Predictions.InvalidStandings.selector);
        predictions.replaceStandings(LEAGUE, keccak256("root"), 0, bytes32(0), "");
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

    function test_RescheduleRejectsZeroTipOff() public {
        bytes32 game = _registerGames(1, T0 + 1 days)[0];
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.InvalidGameInfo.selector, game));
        registry.rescheduleGame(game, 0);
    }

    function test_PauseAndUnpause() public {
        vm.startPrank(admin);
        registry.pause();
        registry.unpause();
        predictions.pause();
        predictions.unpause();
        badge.pause();
        vm.stopPrank();

        vm.prank(minter);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        badge.claim(LEAGUE, alice, LeagueBadge.BadgeStats(1, 0, 0, 0, 0), new bytes32[](0));

        vm.prank(admin);
        badge.unpause();
        vm.prank(minter);
        vm.expectRevert(LeagueBadge.ZeroAddress.selector);
        badge.claim(LEAGUE, address(0), LeagueBadge.BadgeStats(1, 0, 0, 0, 0), new bytes32[](0));
    }

    function test_LeagueDisplayIsReadable() public {
        vm.prank(operator);
        badge.setLeagueDisplay(LEAGUE, "MBL", "2026-27");
        LeagueBadge.LeagueDisplay memory d = badge.getLeagueDisplay(LEAGUE);
        assertEq(d.name, "MBL");
        assertEq(d.season, "2026-27");
    }

    function test_GameViewsForUnknownGame() public view {
        (bool isFinal_, IResultsRegistry.GameStatus status, , uint64 tipOff) = registry.outcomeOf(keccak256("x"));
        assertFalse(isFinal_);
        assertEq(uint8(status), uint8(IResultsRegistry.GameStatus.None));
        assertEq(tipOff, 0);
    }
}
