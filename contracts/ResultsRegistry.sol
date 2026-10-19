// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {AccessControlDefaultAdminRules} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IResultsRegistry} from "./interfaces/IResultsRegistry.sol";

/// @title ResultsRegistry
/// @notice Per-game results of the real-world competition (volleyball), keyed by game so that one
///         file per game or one file per matchday makes no difference. Each game is registered with
///         its format (`targetScore`, `drawAllowed`), which is what a result is checked against: so
///         another head-to-head sport needs no change here.
///
///         Lifecycle of a game:
///           registerGames (operator)  ->  Scheduled (only with a future start time)
///           rescheduleGame (operator) ->  Scheduled, new start time (only before the start)
///           recordResults (relayer)   ->  Final | Forfeit | Void (never before the start time)
///           voidGame (steward)        ->  Void (only when no result arrived within
///                                         `postponeWindow` after the start time)
///           correctResult (steward)   ->  Final | Forfeit | Void, once, within `correctionWindow`
///                                         of the result; after that the result never changes
///
///         Results come from LocalTruth attestations of an accredited institutional source: the
///         relayer verifies that the public file's SHA-256 equals the attested `sha256_pub` and
///         stores it as `sourceHash`, so anyone can re-check a stored result against the attested
///         file. A result written wrong (a parser bug, a wrong attestation) can be corrected once
///         by the steward, with the same checks. Predictions settles a round only once none of its
///         results can change and `finalizationDelay` has passed since the last of them.
///
///         Pause: the steward stops every write but `correctResult` in minutes; only the admin
///         (cold wallet) resumes.
contract ResultsRegistry is IResultsRegistry, AccessControlDefaultAdminRules, Pausable {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant RESULTS_RELAYER_ROLE = keccak256("RESULTS_RELAYER_ROLE");
    bytes32 public constant STEWARD_ROLE = keccak256("STEWARD_ROLE");

    uint256 public constant MAX_BATCH = 100;
    uint64 public constant MIN_POSTPONE_WINDOW = 1 days;
    uint64 public constant MAX_POSTPONE_WINDOW = 30 days;
    uint64 public constant MIN_CORRECTION_WINDOW = 1 hours;
    uint64 public constant MAX_CORRECTION_WINDOW = 7 days;
    uint256 public constant MAX_ATTESTATION_ID_LENGTH = 128;

    /// @notice Time after the start before a game without a result may be voided (default 7 days).
    uint64 public postponeWindow;

    /// @notice Time after a result during which the steward may correct it, once (default 24 h).
    ///         A change applies to results written after it: a closed window never reopens, so a
    ///         round Predictions already settled can never see one of its results change.
    uint64 public correctionWindow;

    mapping(bytes32 gameId => Game) private _games;

    error ZeroAddress();
    error EmptyBatch();
    error BatchTooLarge(uint256 size, uint256 max);
    error InvalidGameInfo(bytes32 gameId);
    error StartTimeInPast(bytes32 gameId, uint64 startTime);
    error GameAlreadyStarted(bytes32 gameId, uint64 startTime);
    error GameAlreadyRegistered(bytes32 gameId);
    error GameNotScheduled(bytes32 gameId);
    error ResultAlreadyRecorded(bytes32 gameId);
    error TeamsMismatch(bytes32 gameId);
    error InvalidResult(bytes32 gameId);
    error InvalidSource(bytes32 gameId);
    error BeforeStart(bytes32 gameId);
    error PostponeWindowOpen(bytes32 gameId, uint64 voidableAt);
    error NoResult(bytes32 gameId);
    error AlreadyCorrected(bytes32 gameId);
    error CorrectionWindowClosed(bytes32 gameId, uint64 correctableUntil);
    error DelayOutOfRange(uint64 value);

    event GameRegistered(
        bytes32 indexed gameId,
        bytes32 homeTeam,
        bytes32 awayTeam,
        uint64 startTime,
        uint8 targetScore,
        bool drawAllowed
    );
    event GameRescheduled(bytes32 indexed gameId, uint64 oldStartTime, uint64 newStartTime);
    event ResultRecorded(
        bytes32 indexed gameId,
        GameStatus status,
        Side winner,
        uint16 homeScore,
        uint16 awayScore,
        uint8 extraPeriods,
        bytes32 sourceHash,
        string attestationId
    );
    event ResultCorrected(
        bytes32 indexed gameId,
        GameStatus status,
        Side winner,
        uint16 homeScore,
        uint16 awayScore,
        uint8 extraPeriods,
        bytes32 sourceHash,
        string attestationId,
        string reason
    );
    event GameVoided(bytes32 indexed gameId, string reason);
    event PostponeWindowSet(uint64 postponeWindow);
    event CorrectionWindowSet(uint64 correctionWindow);

    /// @dev Every role holder is set here, so the deployer gets no role: any account can deploy.
    constructor(
        uint48 adminDelay,
        address admin,
        uint64 initialPostponeWindow,
        uint64 initialCorrectionWindow,
        address operator,
        address resultsRelayer,
        address steward
    ) AccessControlDefaultAdminRules(adminDelay, admin) {
        if (operator == address(0) || resultsRelayer == address(0) || steward == address(0)) revert ZeroAddress();
        _grantRole(OPERATOR_ROLE, operator);
        _grantRole(RESULTS_RELAYER_ROLE, resultsRelayer);
        _grantRole(STEWARD_ROLE, steward);
        _setPostponeWindow(initialPostponeWindow);
        _setCorrectionWindow(initialCorrectionWindow);
    }

    // ---------------------------------------------------------------------
    // Operator: fixtures
    // ---------------------------------------------------------------------

    /// @notice Register fixtures. Write-once per game. The start time must be in the future, as for
    ///         rescheduleGame: a game registered after its start could never move nor join a round.
    function registerGames(GameInfo[] calldata games) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        _checkBatch(games.length);
        for (uint256 i = 0; i < games.length; ++i) {
            GameInfo calldata info = games[i];
            if (
                info.gameId == bytes32(0) ||
                info.homeTeam == bytes32(0) ||
                info.awayTeam == bytes32(0) ||
                info.homeTeam == info.awayTeam ||
                info.startTime == 0 ||
                (info.targetScore != 0 && info.drawAllowed) // a race to N sets has no draws
            ) revert InvalidGameInfo(info.gameId);
            if (info.startTime <= block.timestamp) revert StartTimeInPast(info.gameId, info.startTime);
            Game storage g = _games[info.gameId];
            if (g.status != GameStatus.None) revert GameAlreadyRegistered(info.gameId);

            g.homeTeam = info.homeTeam;
            g.awayTeam = info.awayTeam;
            g.startTime = info.startTime;
            g.targetScore = info.targetScore;
            g.drawAllowed = info.drawAllowed;
            g.status = GameStatus.Scheduled;
            emit GameRegistered(
                info.gameId,
                info.homeTeam,
                info.awayTeam,
                info.startTime,
                info.targetScore,
                info.drawAllowed
            );
        }
    }

    /// @notice Move a game that has not started yet to a future time. Rounds whose lock is past a
    ///         game's new start time will not count that game (see Predictions.finalizeRound).
    ///         A start time that has passed never moves again: from then on the game only takes a
    ///         result or a void. So at a round's lock the games that can count are fixed: one that
    ///         started before the lock never comes back, one that starts after can only move later.
    ///         A game postponed after its start keeps its start time: the replay's result is
    ///         recorded on the same id, or the steward voids it once `postponeWindow` has passed.
    function rescheduleGame(bytes32 gameId, uint64 newStartTime) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        Game storage g = _games[gameId];
        if (g.status != GameStatus.Scheduled) revert GameNotScheduled(gameId);
        if (block.timestamp >= g.startTime) revert GameAlreadyStarted(gameId, g.startTime);
        if (newStartTime <= block.timestamp) revert StartTimeInPast(gameId, newStartTime);
        uint64 old = g.startTime;
        g.startTime = newStartTime;
        emit GameRescheduled(gameId, old, newStartTime);
    }

    // ---------------------------------------------------------------------
    // Relayer: results
    // ---------------------------------------------------------------------

    /// @notice Record attested results. The whole batch reverts on any invalid item: the relayer
    ///         validates off-chain first, so a revert means a bug or a data problem to look at.
    function recordResults(
        ResultInput[] calldata results
    ) external onlyRole(RESULTS_RELAYER_ROLE) whenNotPaused {
        _checkBatch(results.length);
        for (uint256 i = 0; i < results.length; ++i) {
            ResultInput calldata r = results[i];
            Game storage g = _games[r.gameId];
            if (g.status != GameStatus.Scheduled) {
                if (g.status == GameStatus.None) revert GameNotScheduled(r.gameId);
                revert ResultAlreadyRecorded(r.gameId); // only the steward can correct it
            }
            _writeResult(g, r);
            emit ResultRecorded(
                r.gameId,
                r.status,
                r.winner,
                r.homeScore,
                r.awayScore,
                r.extraPeriods,
                r.sourceHash,
                r.attestationId
            );
        }
    }

    // ---------------------------------------------------------------------
    // Steward: discretionary actions
    // ---------------------------------------------------------------------

    /// @notice Void a game that got no result within `postponeWindow` after its start. Final.
    function voidGame(bytes32 gameId, string calldata reason) external onlyRole(STEWARD_ROLE) whenNotPaused {
        Game storage g = _games[gameId];
        if (g.status != GameStatus.Scheduled) revert GameNotScheduled(gameId);
        uint64 voidableAt = g.startTime + postponeWindow;
        if (block.timestamp <= voidableAt) revert PostponeWindowOpen(gameId, voidableAt);

        g.status = GameStatus.Void;
        g.winner = Side.None;
        g.recordedAt = uint64(block.timestamp);
        g.correctableUntil = uint64(block.timestamp) + correctionWindow;
        emit GameVoided(gameId, reason);
    }

    /// @notice Replace a game's result (or void) with the right one, once, within `correctionWindow`
    ///         of it. Same checks as recordResults; the source may be the same attested file (a
    ///         parser bug) or a new one. `recordedAt` moves to now, so every round of the game
    ///         gives the corrected result a full `finalizationDelay` before settling.
    ///         Works while paused: pausing to stop the relayer, then correcting, is a remedy.
    function correctResult(ResultInput calldata r, string calldata reason) external onlyRole(STEWARD_ROLE) {
        Game storage g = _games[r.gameId];
        if (g.recordedAt == 0) revert NoResult(r.gameId);
        if (g.corrected) revert AlreadyCorrected(r.gameId);
        if (block.timestamp >= g.correctableUntil) revert CorrectionWindowClosed(r.gameId, g.correctableUntil);

        _writeResult(g, r);
        g.correctableUntil = 0;
        g.corrected = true;
        emit ResultCorrected(
            r.gameId,
            r.status,
            r.winner,
            r.homeScore,
            r.awayScore,
            r.extraPeriods,
            r.sourceHash,
            r.attestationId,
            reason
        );
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function setPostponeWindow(uint64 window) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setPostponeWindow(window);
    }

    function setCorrectionWindow(uint64 window) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setCorrectionWindow(window);
    }

    /// @notice The steward's hot wallet can stop the registry in minutes; only the admin resumes it.
    function pause() external onlyRole(STEWARD_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getGame(bytes32 gameId) external view returns (Game memory) {
        return _games[gameId];
    }

    /// @notice Whether the game has a result (or was voided). The steward may still correct it once,
    ///         until `correctableUntil`.
    function hasResult(bytes32 gameId) external view returns (bool) {
        return _games[gameId].recordedAt != 0;
    }

    function correctableUntil(bytes32 gameId) external view returns (uint64) {
        return _games[gameId].correctableUntil;
    }

    function outcomeOf(
        bytes32 gameId
    ) external view returns (GameStatus status, Side winner, uint64 startTime, uint64 recordedAt) {
        Game storage g = _games[gameId];
        return (g.status, g.winner, g.startTime, g.recordedAt);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _writeResult(Game storage g, ResultInput calldata r) private {
        if (r.homeTeam != g.homeTeam || r.awayTeam != g.awayTeam) revert TeamsMismatch(r.gameId);
        _validateResult(g, r);
        // No result before the start, whatever the status. A game cancelled in advance is recorded
        // as Void once its start time has passed: an early Void would let the automated key void
        // any future fixture, while the steward has to wait `postponeWindow` for the same.
        if (block.timestamp < g.startTime) revert BeforeStart(r.gameId);
        uint256 idLength = bytes(r.attestationId).length;
        if (r.sourceHash == bytes32(0) || idLength == 0 || idLength > MAX_ATTESTATION_ID_LENGTH) {
            revert InvalidSource(r.gameId);
        }

        g.status = r.status;
        g.winner = r.winner;
        g.homeScore = r.homeScore;
        g.awayScore = r.awayScore;
        g.extraPeriods = r.extraPeriods;
        g.sourceHash = r.sourceHash; // the attestation id lives in the ResultRecorded event
        g.recordedAt = uint64(block.timestamp);
        g.correctableUntil = uint64(block.timestamp) + correctionWindow;
    }

    /// @dev Catches parser bugs: the stored result must be consistent with the game's format.
    function _validateResult(Game storage g, ResultInput calldata r) private view {
        bool ok = false; // any other status stays invalid
        uint8 target = g.targetScore;
        if (r.status == GameStatus.Final) {
            if (r.homeScore == r.awayScore) {
                ok = r.winner == Side.Draw && g.drawAllowed;
            } else {
                // The winner is the side ahead; in a race to N sets it reached N, with no extra periods.
                bool homeLeads = r.homeScore > r.awayScore;
                uint16 winnerScore = homeLeads ? r.homeScore : r.awayScore;
                ok =
                    r.winner == (homeLeads ? Side.Home : Side.Away) &&
                    (target == 0 || (winnerScore == target && r.extraPeriods == 0));
            }
        } else if (r.status == GameStatus.Forfeit) {
            // Forfeited before the start (no score) or during the game with the winner ahead.
            bool noScore = r.homeScore == 0 && r.awayScore == 0;
            bool winnerLeads = (r.winner == Side.Home && r.homeScore > r.awayScore) ||
                (r.winner == Side.Away && r.awayScore > r.homeScore);
            ok =
                (r.winner == Side.Home || r.winner == Side.Away) &&
                r.extraPeriods == 0 &&
                (noScore || winnerLeads) &&
                (target == 0 || (r.homeScore <= target && r.awayScore <= target));
        } else if (r.status == GameStatus.Void) {
            ok = r.winner == Side.None && r.homeScore == 0 && r.awayScore == 0 && r.extraPeriods == 0;
        }
        if (!ok) revert InvalidResult(r.gameId);
    }

    function _checkBatch(uint256 size) private pure {
        if (size == 0) revert EmptyBatch();
        if (size > MAX_BATCH) revert BatchTooLarge(size, MAX_BATCH);
    }

    function _setPostponeWindow(uint64 window) private {
        if (window < MIN_POSTPONE_WINDOW || window > MAX_POSTPONE_WINDOW) revert DelayOutOfRange(window);
        postponeWindow = window;
        emit PostponeWindowSet(window);
    }

    function _setCorrectionWindow(uint64 window) private {
        if (window < MIN_CORRECTION_WINDOW || window > MAX_CORRECTION_WINDOW) revert DelayOutOfRange(window);
        correctionWindow = window;
        emit CorrectionWindowSet(window);
    }
}
