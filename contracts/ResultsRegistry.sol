// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControlDefaultAdminRules} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IResultsRegistry} from "./interfaces/IResultsRegistry.sol";

/// @title ResultsRegistry
/// @notice Per-game results of the Mongolian basketball league, keyed by game so that one file per
///         game or one file per matchday makes no difference.
///
///         Lifecycle of a game:
///           registerGames (operator)  ->  Scheduled
///           recordResults (relayer)   ->  Final | Forfeit | Void, final as soon as it is written
///           voidGame (steward)        ->  Void, final (only when no result arrived within
///                                         `postponeWindow` after tip-off)
///
///         Results come from LocalTruth attestations of an accredited institutional source: the
///         relayer verifies that the public file's SHA-256 equals the attested `sha256_pub` and
///         stores it as `sourceHash`, so anyone can re-check a stored result against the attested
///         file. A recorded result never changes: there is no correction or challenge period.
contract ResultsRegistry is IResultsRegistry, AccessControlDefaultAdminRules, Pausable {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant RESULTS_RELAYER_ROLE = keccak256("RESULTS_RELAYER_ROLE");
    bytes32 public constant STEWARD_ROLE = keccak256("STEWARD_ROLE");

    uint256 public constant MAX_BATCH = 100;
    uint64 public constant MIN_POSTPONE_WINDOW = 1 days;
    uint64 public constant MAX_POSTPONE_WINDOW = 30 days;
    uint256 public constant MAX_ATTESTATION_ID_LENGTH = 128;

    /// @notice Time after tip-off before a game without a result may be voided (default 7 days).
    uint64 public postponeWindow;

    mapping(bytes32 gameId => Game) private _games;

    error EmptyBatch();
    error BatchTooLarge(uint256 size, uint256 max);
    error InvalidGameInfo(bytes32 gameId);
    error GameAlreadyRegistered(bytes32 gameId);
    error GameNotScheduled(bytes32 gameId);
    error ResultAlreadyRecorded(bytes32 gameId);
    error TeamsMismatch(bytes32 gameId);
    error InvalidResult(bytes32 gameId);
    error InvalidSource(bytes32 gameId);
    error BeforeTipOff(bytes32 gameId);
    error PostponeWindowOpen(bytes32 gameId, uint64 voidableAt);
    error DelayOutOfRange(uint64 value);

    event GameRegistered(bytes32 indexed gameId, bytes32 homeTeam, bytes32 awayTeam, uint64 tipOff);
    event GameRescheduled(bytes32 indexed gameId, uint64 oldTipOff, uint64 newTipOff);
    event ResultRecorded(
        bytes32 indexed gameId,
        GameStatus status,
        Side winner,
        uint16 homeScore,
        uint16 awayScore,
        uint8 overtimes,
        bytes32 sourceHash,
        string attestationId
    );
    event GameVoided(bytes32 indexed gameId, string reason);
    event PostponeWindowSet(uint64 postponeWindow);

    constructor(
        uint48 adminDelay,
        address admin,
        uint64 initialPostponeWindow
    ) AccessControlDefaultAdminRules(adminDelay, admin) {
        _setPostponeWindow(initialPostponeWindow);
    }

    // ---------------------------------------------------------------------
    // Operator: fixtures
    // ---------------------------------------------------------------------

    /// @notice Register fixtures. Write-once per game.
    function registerGames(GameInfo[] calldata games) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        _checkBatch(games.length);
        for (uint256 i = 0; i < games.length; ++i) {
            GameInfo calldata info = games[i];
            if (
                info.gameId == bytes32(0) ||
                info.homeTeam == bytes32(0) ||
                info.awayTeam == bytes32(0) ||
                info.homeTeam == info.awayTeam ||
                info.tipOff == 0
            ) revert InvalidGameInfo(info.gameId);
            Game storage g = _games[info.gameId];
            if (g.status != GameStatus.None) revert GameAlreadyRegistered(info.gameId);

            g.homeTeam = info.homeTeam;
            g.awayTeam = info.awayTeam;
            g.tipOff = info.tipOff;
            g.status = GameStatus.Scheduled;
            emit GameRegistered(info.gameId, info.homeTeam, info.awayTeam, info.tipOff);
        }
    }

    /// @notice Move a game that has no result yet. Rounds whose lock is past a game's new tip-off
    ///         will not count that game (see Predictions.finalizeRound).
    function rescheduleGame(bytes32 gameId, uint64 newTipOff) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        Game storage g = _games[gameId];
        if (g.status != GameStatus.Scheduled) revert GameNotScheduled(gameId);
        if (newTipOff == 0) revert InvalidGameInfo(gameId);
        uint64 old = g.tipOff;
        g.tipOff = newTipOff;
        emit GameRescheduled(gameId, old, newTipOff);
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
                revert ResultAlreadyRecorded(r.gameId); // a recorded result is final
            }
            _writeResult(g, r);
            emit ResultRecorded(
                r.gameId,
                r.status,
                r.winner,
                r.homeScore,
                r.awayScore,
                r.overtimes,
                r.sourceHash,
                r.attestationId
            );
        }
    }

    // ---------------------------------------------------------------------
    // Steward: discretionary actions
    // ---------------------------------------------------------------------

    /// @notice Void a game that got no result within `postponeWindow` after tip-off. Final.
    function voidGame(bytes32 gameId, string calldata reason) external onlyRole(STEWARD_ROLE) {
        Game storage g = _games[gameId];
        if (g.status != GameStatus.Scheduled) revert GameNotScheduled(gameId);
        uint64 voidableAt = g.tipOff + postponeWindow;
        if (block.timestamp <= voidableAt) revert PostponeWindowOpen(gameId, voidableAt);

        g.status = GameStatus.Void;
        g.winner = Side.None;
        g.recordedAt = uint64(block.timestamp);
        emit GameVoided(gameId, reason);
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function setPostponeWindow(uint64 window) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setPostponeWindow(window);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
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

    /// @notice A game is final once it has a result (or was voided): results never change.
    function isFinal(bytes32 gameId) public view returns (bool) {
        return _games[gameId].recordedAt != 0;
    }

    function outcomeOf(
        bytes32 gameId
    ) external view returns (bool isFinal_, GameStatus status, Side winner, uint64 tipOff) {
        Game storage g = _games[gameId];
        return (isFinal(gameId), g.status, g.winner, g.tipOff);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _writeResult(Game storage g, ResultInput calldata r) private {
        if (r.homeTeam != g.homeTeam || r.awayTeam != g.awayTeam) revert TeamsMismatch(r.gameId);
        _validateResult(r);
        // A played or forfeited game cannot have a result before it started. A void (cancelled)
        // game can: nobody scores on it, so knowing it early gives no advantage.
        if (r.status != GameStatus.Void && block.timestamp < g.tipOff) revert BeforeTipOff(r.gameId);
        uint256 idLength = bytes(r.attestationId).length;
        if (r.sourceHash == bytes32(0) || idLength == 0 || idLength > MAX_ATTESTATION_ID_LENGTH) {
            revert InvalidSource(r.gameId);
        }

        g.status = r.status;
        g.winner = r.winner;
        g.homeScore = r.homeScore;
        g.awayScore = r.awayScore;
        g.overtimes = r.overtimes;
        g.sourceHash = r.sourceHash;
        g.attestationKey = keccak256(bytes(r.attestationId));
        g.recordedAt = uint64(block.timestamp);
    }

    /// @dev Catches parser bugs: the stored result must be internally consistent.
    function _validateResult(ResultInput calldata r) private pure {
        bool ok;
        if (r.status == GameStatus.Final) {
            // No draws in basketball; the winner is the side with more points.
            ok =
                r.homeScore != r.awayScore &&
                r.winner == (r.homeScore > r.awayScore ? Side.Home : Side.Away);
        } else if (r.status == GameStatus.Forfeit) {
            bool noScore = r.homeScore == 0 && r.awayScore == 0;
            bool winnerLeads = r.winner == Side.Home
                ? r.homeScore > r.awayScore
                : r.awayScore > r.homeScore;
            ok = r.winner != Side.None && r.overtimes == 0 && (noScore || winnerLeads);
        } else if (r.status == GameStatus.Void) {
            ok = r.winner == Side.None && r.homeScore == 0 && r.awayScore == 0 && r.overtimes == 0;
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
}
