// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IPredictions
/// @notice Read surface of the Predictions contract used by LeagueBadge and off-chain verifiers.
interface IPredictions {
    struct League {
        bool exists;
        bool finalized;
        uint16 roundCount;
        uint32 totalPlayers;
        uint64 finalizedAt;
        uint64 claimsOpenAt;
        bytes32 metadataHash;
        bytes32 standingsRoot;
        bytes32 reportHash;
    }

    /// @notice Aggregated, on-chain recomputable stats of a player in a league (scoring layer 0).
    struct LeagueStats {
        uint32 points; // +1 per correct pick
        uint32 correct;
        uint32 counted; // picks on games that counted (void games excluded)
        uint16 roundsPlayed; // finalized rounds with a submission and at least one counted game
        uint64 sumLeadTime; // sum over rounds played of (lockTime - confirmedAt), for the tie-break
    }

    function getLeague(bytes32 leagueId) external view returns (League memory);

    function leagueStatsOf(
        bytes32 leagueId,
        address user
    ) external view returns (LeagueStats memory);
}
