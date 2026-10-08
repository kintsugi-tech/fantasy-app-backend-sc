// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IResultsRegistry
/// @notice Per-game results of the real-world competition, anchored to LocalTruth attestations.
///
///         The scores are the unit that decides the winner (sets in volleyball); partial scores
///         (set by set) stay in the attested file, which `sourceHash` points to. Each game carries
///         its format, so another head-to-head sport needs no change here.
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
    ///           targetScore N   the winner is the first side to reach N (volleyball: 3 sets)
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

    /// @notice A result read from an attested MSC file.
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
        uint64 recordedAt; // 0 while no result; once set, the result is final
        GameStatus status;
        Side winner;
        uint16 homeScore;
        uint16 awayScore;
        uint8 extraPeriods;
        uint8 targetScore;
        bool drawAllowed;
        bytes32 sourceHash; // the attestation id is in the ResultRecorded event
    }

    function getGame(bytes32 gameId) external view returns (Game memory);

    /// @notice Whether the game has a result (or was voided). Results never change once recorded.
    function isFinal(bytes32 gameId) external view returns (bool);

    /// @notice Compact view (one slot) used by Predictions to schedule and settle rounds.
    ///         `recordedAt` is 0 until the game has a result or was voided.
    function outcomeOf(
        bytes32 gameId
    ) external view returns (GameStatus status, Side winner, uint64 startTime, uint64 recordedAt);
}
