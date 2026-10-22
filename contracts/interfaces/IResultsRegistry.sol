// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IResultsRegistry
/// @notice Per-game results of real-world sports competitions, anchored to LocalTruth attestations.
///
///         The scores are the unit that decides the winner (e.g. sets, points or goals, depending on
///         the sport); partial scores stay in the attested file, which `sourceHash` points to. Each
///         game carries its format, so any head-to-head sport needs no change here.
interface IResultsRegistry {
    enum GameStatus {
        None, // never registered
        Scheduled, // registered, no result yet
        Final, // played, attested result
        Forfeit, // decided by forfeit
        Void // cancelled / not played (attested) or voided by the steward
    }

    /// @dev Draw is 3 so that every side fits in the 2 bits per game Predictions packs picks into.
    enum Side {
        None,
        Home,
        Away,
        Draw
    }

    /// @notice Fixture data, registered before the game can be used in a round.
    ///         The format says how a result is checked:
    ///           targetScore N   the winner is the first side to reach N (e.g. 3 sets in a best of 5)
    ///           targetScore 0   open score: the side ahead wins
    ///           drawAllowed     an open score may end level (Side.Draw)
    struct GameInfo {
        bytes32 gameId; // keccak256(bytes(canonicalGameId))
        bytes32 homeTeam; // team (or player) code as a bytes32 short string
        bytes32 awayTeam;
        uint64 startTime; // unix seconds (UTC)
        uint8 targetScore; // 0: open score; N: the winner is the first side to reach N
        bool drawAllowed; // only with an open score
    }

    /// @notice A result read from an attested results file.
    struct ResultInput {
        bytes32 gameId;
        bytes32 homeTeam; // must match the registered fixture (guards against a home/away swap)
        bytes32 awayTeam;
        GameStatus status; // Final | Forfeit | Void
        Side winner;
        uint16 homeScore;
        uint16 awayScore;
        uint8 extraPeriods; // periods past regulation, where the sport has them (never with a target)
        bytes32 sourceHash; // SHA-256 of the attested public file (decoded from base64 sha256_pub)
        string attestationId; // LocalTruth competition_id the file was attested under
    }

    struct Game {
        bytes32 homeTeam;
        bytes32 awayTeam;
        uint64 startTime;
        uint64 recordedAt; // 0 while no result; set again by a correction
        GameStatus status;
        Side winner;
        uint16 homeScore;
        uint16 awayScore;
        uint8 extraPeriods;
        uint8 targetScore;
        bool drawAllowed;
        bytes32 sourceHash; // the attestation id is in the ResultRecorded / ResultCorrected event
        uint64 correctableUntil; // set with the result (recordedAt + correctionWindow); 0 once corrected
        bool corrected; // the steward corrected the result: it can never change again
    }

    function getGame(bytes32 gameId) external view returns (Game memory);

    /// @notice Whether the game has a result (or was voided). The steward may still correct it once,
    ///         until `correctableUntil`.
    function hasResult(bytes32 gameId) external view returns (bool);

    /// @notice Until when the steward may correct the game's result: 0 while it has no result or
    ///         once it was corrected, after which the result never changes. Fixed when the result
    ///         is written, so a later change of the correction window never reopens it.
    function correctableUntil(bytes32 gameId) external view returns (uint64);

    /// @notice Compact view (one slot) used by Predictions to schedule and settle rounds.
    ///         `recordedAt` is 0 until the game has a result or was voided.
    function outcomeOf(
        bytes32 gameId
    ) external view returns (GameStatus status, Side winner, uint64 startTime, uint64 recordedAt);
}
