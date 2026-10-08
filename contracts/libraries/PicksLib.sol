// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title PicksLib
/// @notice Picks schema 1 (scoring layer 0): one byte per game, in the round's game order,
///         1 = home wins, 2 = away wins, 3 = draw (the values of IResultsRegistry.Side).
///         Every game must be picked. A draw pick is accepted on any game: where the registry
///         does not allow draws it can never match the outcome, and the app does not offer it.
///         On-chain, picks and round outcomes are packed 2 bits per game into a uint64
///         (max 32 games); outcome 0 means "game not counted" (void, or played before the lock).
library PicksLib {
    uint8 internal constant HOME = 1;
    uint8 internal constant AWAY = 2;
    uint8 internal constant DRAW = 3;

    /// @return ok false if any pick is not HOME/AWAY/DRAW
    function pack(bytes calldata picks) internal pure returns (bool ok, uint64 packed) {
        for (uint256 i = 0; i < picks.length; ++i) {
            uint8 p = uint8(picks[i]);
            if (p < HOME || p > DRAW) return (false, 0);
            packed |= uint64(p) << uint8(2 * i); // callers bound picks.length to 32
        }
        return (true, packed);
    }

    function unpack(uint64 packed, uint256 count) internal pure returns (bytes memory picks) {
        picks = new bytes(count);
        for (uint256 i = 0; i < count; ++i) {
            picks[i] = bytes1(pickAt(packed, i));
        }
    }

    function pickAt(uint64 packed, uint256 i) internal pure returns (uint8) {
        return uint8((packed >> (2 * i)) & 3);
    }

    /// @notice Layer-0 score: +1 per correct pick on a counted game.
    function score(
        uint64 picks,
        uint64 outcomes,
        uint256 count
    ) internal pure returns (uint8 correct, uint8 counted) {
        for (uint256 i = 0; i < count; ++i) {
            uint8 o = pickAt(outcomes, i);
            if (o == 0) continue;
            ++counted;
            if (pickAt(picks, i) == o) ++correct;
        }
    }

    function countedGames(uint64 outcomes, uint256 count) internal pure returns (uint8 counted) {
        for (uint256 i = 0; i < count; ++i) {
            if (pickAt(outcomes, i) != 0) ++counted;
        }
    }
}
