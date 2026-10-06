// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IResultsRegistry
/// @notice Per-game results of the real-world competition, anchored to LocalTruth attestations.
interface IResultsRegistry {
    enum GameStatus {
        None, // never registered
        Scheduled, // registered, no result yet
        Final, // played, attested result
        Forfeit, // decided by forfeit
        Void // cancelled / not played (attested) or voided by the steward
    }

    enum Side {
        None,
        Home,
        Away
    }

    /// @notice Fixture data, registered before the game can be used in a round.
    struct GameInfo {
        bytes32 gameId; // keccak256(bytes(canonicalGameId))
        bytes32 homeTeam; // team code as a bytes32 short string
        bytes32 awayTeam;
        uint64 tipOff; // unix seconds (UTC)
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
        uint8 overtimes;
        bytes32 sourceHash; // SHA-256 of the attested public file (decoded from base64 sha256_pub)
        string attestationId; // LocalTruth competition_id the file was attested under
    }

    struct Game {
        bytes32 homeTeam;
        bytes32 awayTeam;
        uint64 tipOff;
        uint64 recordedAt; // 0 while no result; once set, the result is final
        GameStatus status;
        Side winner;
        uint16 homeScore;
        uint16 awayScore;
        uint8 overtimes;
        bytes32 sourceHash; // the attestation id is in the ResultRecorded event
    }

    function getGame(bytes32 gameId) external view returns (Game memory);

    /// @notice Whether the game has a result (or was voided). Results never change once recorded.
    function isFinal(bytes32 gameId) external view returns (bool);

    /// @notice Compact view (one slot) used by Predictions to schedule and settle rounds.
    ///         `recordedAt` is 0 until the game has a result or was voided.
    function outcomeOf(
        bytes32 gameId
    ) external view returns (GameStatus status, Side winner, uint64 tipOff, uint64 recordedAt);
}
