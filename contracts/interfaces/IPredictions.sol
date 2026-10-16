// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IPredictions
/// @notice Read surface of the Predictions contract used by off-chain verifiers.
interface IPredictions {
    struct League {
        bool exists;
        bool finalized;
        uint16 roundCount;
        uint32 totalPlayers;
        uint64 finalizedAt;
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

    /// @notice One row of the final standings: a leaf of the OZ StandardMerkleTree whose root
    ///         finalizeLeague anchors. The stats are those of leagueStatsOf.
    struct StandingLeaf {
        bytes32 leagueId;
        address account;
        uint32 rank;
        uint32 points;
        uint32 correct;
        uint32 counted;
        uint16 roundsPlayed;
        uint64 sumLeadTime;
    }

    /// @notice Standings proposed by the steward, anchored by finalizeLeague after the review period.
    struct StandingsProposal {
        bytes32 standingsRoot;
        bytes32 reportHash;
        uint32 totalPlayers;
        uint64 proposedAt; // 0 = no proposal
        uint16 roundCount; // rounds the standings cover (no round can be added while proposed)
    }

    function getLeague(bytes32 leagueId) external view returns (League memory);

    function getStandingsProposal(bytes32 leagueId) external view returns (StandingsProposal memory);

    function leagueStatsOf(
        bytes32 leagueId,
        address user
    ) external view returns (LeagueStats memory);

    function checkStanding(
        bytes32 leagueId,
        StandingLeaf calldata leaf,
        bytes32[] calldata proof
    ) external view returns (bool inTree, bool matchesChain);
}
