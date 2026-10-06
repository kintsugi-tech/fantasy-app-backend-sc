// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IResultsRegistry} from "../contracts/interfaces/IResultsRegistry.sol";
import {ResultsRegistry} from "../contracts/ResultsRegistry.sol";
import {M2Base} from "./utils/M2Base.sol";

contract ResultsRegistryTest is M2Base {
    bytes32 internal game;
    uint64 internal tipOff;

    function setUp() public override {
        super.setUp();
        tipOff = T0 + 1 days;
        game = _registerGames(1, tipOff)[0];
    }

    // --- registerGames ---------------------------------------------------------

    function test_RegisterStoresFixture() public view {
        IResultsRegistry.Game memory g = registry.getGame(game);
        assertEq(uint8(g.status), uint8(IResultsRegistry.GameStatus.Scheduled));
        assertEq(g.homeTeam, _homeTeam(1));
        assertEq(g.awayTeam, _awayTeam(1));
        assertEq(g.tipOff, tipOff);
        assertEq(g.recordedAt, 0);
        assertFalse(registry.isFinal(game));
    }

    function test_RegisterIsWriteOnce() public {
        IResultsRegistry.GameInfo[] memory infos = new IResultsRegistry.GameInfo[](1);
        infos[0] = IResultsRegistry.GameInfo(game, _homeTeam(9), _awayTeam(9), tipOff);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.GameAlreadyRegistered.selector, game));
        registry.registerGames(infos);
    }

    function test_RegisterRejectsInvalidInfo() public {
        IResultsRegistry.GameInfo[] memory infos = new IResultsRegistry.GameInfo[](1);
        bytes32 id = _gameId(999);

        infos[0] = IResultsRegistry.GameInfo(id, _homeTeam(1), _homeTeam(1), tipOff); // same teams
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.InvalidGameInfo.selector, id));
        registry.registerGames(infos);

        infos[0] = IResultsRegistry.GameInfo(id, _homeTeam(1), _awayTeam(1), 0); // no tip-off
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.InvalidGameInfo.selector, id));
        registry.registerGames(infos);

        infos[0] = IResultsRegistry.GameInfo(bytes32(0), _homeTeam(1), _awayTeam(1), tipOff);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.InvalidGameInfo.selector, bytes32(0)));
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

    function test_RescheduleRejectsPastTipOff() public {
        vm.warp(T0 + 1 hours);
        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.TipOffInPast.selector, game, uint64(T0)));
        registry.rescheduleGame(game, T0);
        vm.expectRevert(
            abi.encodeWithSelector(ResultsRegistry.TipOffInPast.selector, game, uint64(block.timestamp))
        );
        registry.rescheduleGame(game, uint64(block.timestamp));
        registry.rescheduleGame(game, uint64(block.timestamp) + 1);
        vm.stopPrank();
        assertEq(registry.getGame(game).tipOff, block.timestamp + 1);
    }

    function test_RescheduleOnlyWithoutResult() public {
        vm.prank(operator);
        registry.rescheduleGame(game, tipOff + 1 hours);
        assertEq(registry.getGame(game).tipOff, tipOff + 1 hours);

        vm.warp(tipOff + 3 hours);
        _record(_final(game, true));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.GameNotScheduled.selector, game));
        registry.rescheduleGame(game, tipOff + 5 hours);
    }

    // --- recordResults ---------------------------------------------------------

    function test_RecordFinalResult() public {
        vm.warp(tipOff + 2 hours);
        IResultsRegistry.ResultInput memory r = _final(game, false);
        vm.expectEmit(address(registry));
        emit ResultsRegistry.ResultRecorded(
            game,
            IResultsRegistry.GameStatus.Final,
            IResultsRegistry.Side.Away,
            75,
            91,
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

    function test_RecordOvertimeResult() public {
        vm.warp(tipOff + 3 hours);
        IResultsRegistry.ResultInput memory r = _final(game, true);
        r.overtimes = 2;
        _record(r);
        assertEq(registry.getGame(game).overtimes, 2);
    }

    function test_RecordRejectsResultBeforeTipOff() public {
        IResultsRegistry.ResultInput memory played = _final(game, true);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.BeforeTipOff.selector, game));
        this.recordAsRelayer(played);

        IResultsRegistry.ResultInput memory forfeit = _result(
            game,
            IResultsRegistry.GameStatus.Forfeit,
            IResultsRegistry.Side.Home,
            20,
            0
        );
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.BeforeTipOff.selector, game));
        this.recordAsRelayer(forfeit);
    }

    function test_RecordVoidOnlyFromTipOff() public {
        IResultsRegistry.ResultInput memory void_ = _result(
            game,
            IResultsRegistry.GameStatus.Void,
            IResultsRegistry.Side.None,
            0,
            0
        );
        vm.warp(tipOff - 1);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.BeforeTipOff.selector, game));
        this.recordAsRelayer(void_);

        vm.warp(tipOff);
        _record(void_);
        assertEq(uint8(registry.getGame(game).status), uint8(IResultsRegistry.GameStatus.Void));
    }

    function test_RecordRejectsSwappedTeams() public {
        vm.warp(tipOff + 2 hours);
        IResultsRegistry.ResultInput memory r = _final(game, true);
        (r.homeTeam, r.awayTeam) = (r.awayTeam, r.homeTeam);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.TeamsMismatch.selector, game));
        this.recordAsRelayer(r);
    }

    function test_RecordRejectsInconsistentResults() public {
        vm.warp(tipOff + 2 hours);
        IResultsRegistry.ResultInput memory r;

        r = _result(game, IResultsRegistry.GameStatus.Final, IResultsRegistry.Side.Home, 80, 80); // draw
        _expectInvalid(r);
        r = _result(game, IResultsRegistry.GameStatus.Final, IResultsRegistry.Side.Home, 70, 80); // wrong winner
        _expectInvalid(r);
        r = _result(game, IResultsRegistry.GameStatus.Final, IResultsRegistry.Side.None, 90, 80);
        _expectInvalid(r);
        r = _result(game, IResultsRegistry.GameStatus.Forfeit, IResultsRegistry.Side.None, 0, 0);
        _expectInvalid(r);
        r = _result(game, IResultsRegistry.GameStatus.Forfeit, IResultsRegistry.Side.Away, 20, 0);
        _expectInvalid(r);
        r = _result(game, IResultsRegistry.GameStatus.Forfeit, IResultsRegistry.Side.Home, 20, 0);
        r.overtimes = 1;
        _expectInvalid(r);
        r = _result(game, IResultsRegistry.GameStatus.Void, IResultsRegistry.Side.Home, 0, 0);
        _expectInvalid(r);
        r = _result(game, IResultsRegistry.GameStatus.Void, IResultsRegistry.Side.None, 10, 0);
        _expectInvalid(r);
        r = _result(game, IResultsRegistry.GameStatus.Scheduled, IResultsRegistry.Side.Home, 90, 80);
        _expectInvalid(r);
    }

    function test_RecordForfeitWithoutScore() public {
        vm.warp(tipOff);
        _record(_result(game, IResultsRegistry.GameStatus.Forfeit, IResultsRegistry.Side.Away, 0, 0));
        assertEq(uint8(registry.getGame(game).winner), uint8(IResultsRegistry.Side.Away));
    }

    function test_RecordRejectsMissingSource() public {
        vm.warp(tipOff + 2 hours);
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
        vm.warp(tipOff + 2 hours);
        _record(_final(game, true));
        vm.warp(block.timestamp + 30 days);
        IResultsRegistry.ResultInput memory again = _final(game, false);
        again.attestationId = "mbl_2026_game-0001-v2";
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.ResultAlreadyRecorded.selector, game));
        this.recordAsRelayer(again);
        assertEq(uint8(registry.getGame(game).winner), uint8(IResultsRegistry.Side.Home));
    }

    function test_RecordRejectsUnknownGame() public {
        vm.warp(tipOff + 2 hours);
        IResultsRegistry.ResultInput memory r = _final(game, true);
        r.gameId = _gameId(777);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.GameNotScheduled.selector, r.gameId));
        this.recordAsRelayer(r);
    }

    function test_RecordOnlyRelayerAndNotPaused() public {
        vm.warp(tipOff + 2 hours);
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
        registry.rescheduleGame(game, tipOff + 1 hours);

        vm.warp(tipOff + POSTPONE + 1);
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
        assertEq(registry.getGame(game).tipOff, tipOff);
        assertFalse(registry.isFinal(game));
    }

    // --- voidGame --------------------------------------------------------------

    function test_VoidAfterPostponeWindow() public {
        uint64 voidableAt = tipOff + POSTPONE;
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
        vm.warp(tipOff + POSTPONE + 1);
        bytes32 role = registry.STEWARD_ROLE();
        vm.prank(resultsRelayer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, resultsRelayer, role)
        );
        registry.voidGame(game, "relayer cannot void");
    }

    function test_VoidRejectedWhenResultExists() public {
        vm.warp(tipOff + 2 hours);
        _record(_final(game, true));
        vm.warp(tipOff + POSTPONE + 1);
        vm.prank(steward);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.GameNotScheduled.selector, game));
        registry.voidGame(game, "has a result");
    }

    // --- admin -----------------------------------------------------------------

    function test_AdminParameterBounds() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.DelayOutOfRange.selector, uint64(1 hours)));
        registry.setPostponeWindow(1 hours);
        vm.expectRevert(abi.encodeWithSelector(ResultsRegistry.DelayOutOfRange.selector, uint64(31 days)));
        registry.setPostponeWindow(31 days);
        registry.setPostponeWindow(2 days);
        vm.stopPrank();
        assertEq(registry.postponeWindow(), 2 days);
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
