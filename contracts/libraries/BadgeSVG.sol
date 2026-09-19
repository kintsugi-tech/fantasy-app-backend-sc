// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title BadgeSVG
/// @notice Fully on-chain metadata (JSON + SVG) for LeagueBadge, so a badge survives our servers.
/// @dev Text inputs are validated by LeagueBadge.setLeagueDisplay (no JSON/SVG metacharacters).
library BadgeSVG {
    using Strings for uint256;

    struct Params {
        uint256 tokenId;
        string leagueName;
        string season;
        uint32 rank;
        uint32 totalPlayers;
        uint32 points;
        uint32 correct;
        uint32 counted;
        uint16 roundsPlayed;
    }

    function tokenURI(Params memory p) internal pure returns (string memory) {
        string memory image = string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(svg(p))));
        string memory json = string.concat(
            '{"name":"',
            p.leagueName,
            " ",
            p.season,
            " - #",
            uint256(p.rank).toString(),
            '","description":"Soulbound badge with the final standing in an M2 league. ',
            'Points are recomputable on-chain from the Predictions contract.","image":"',
            image,
            '","attributes":',
            _attributes(p),
            "}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function svg(Params memory p) internal pure returns (string memory) {
        return
            string.concat(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 360 360" font-family="sans-serif">',
                '<rect width="360" height="360" rx="24" fill="#0b1220"/>',
                '<circle cx="300" cy="60" r="34" fill="none" stroke="#f59e0b" stroke-width="4"/>',
                _text(24, 64, 20, "#f8fafc", p.leagueName),
                _text(24, 92, 14, "#94a3b8", p.season),
                _text(24, 190, 64, "#f59e0b", string.concat("#", uint256(p.rank).toString())),
                _text(24, 222, 14, "#94a3b8", string.concat("of ", uint256(p.totalPlayers).toString(), " players")),
                _stats(p),
                "</svg>"
            );
    }

    function _stats(Params memory p) private pure returns (string memory) {
        return
            string.concat(
                _text(24, 290, 16, "#f8fafc", string.concat(uint256(p.points).toString(), " pts")),
                _text(
                    130,
                    290,
                    16,
                    "#f8fafc",
                    string.concat(uint256(p.correct).toString(), "/", uint256(p.counted).toString(), " correct")
                ),
                _text(24, 320, 14, "#94a3b8", string.concat(uint256(p.roundsPlayed).toString(), " matchdays played"))
            );
    }

    function _text(
        uint256 x,
        uint256 y,
        uint256 size,
        string memory fill,
        string memory content
    ) private pure returns (string memory) {
        return
            string.concat(
                '<text x="',
                x.toString(),
                '" y="',
                y.toString(),
                '" font-size="',
                size.toString(),
                '" fill="',
                fill,
                '">',
                content,
                "</text>"
            );
    }

    function _attributes(Params memory p) private pure returns (string memory) {
        return
            string.concat(
                "[",
                _attr("League", string.concat('"', p.leagueName, '"')),
                ",",
                _attr("Season", string.concat('"', p.season, '"')),
                ",",
                _attr("Rank", uint256(p.rank).toString()),
                ",",
                _attr("Players", uint256(p.totalPlayers).toString()),
                ",",
                _attr("Points", uint256(p.points).toString()),
                ",",
                _attr("Correct picks", uint256(p.correct).toString()),
                ",",
                _attr("Counted picks", uint256(p.counted).toString()),
                ",",
                _attr("Matchdays played", uint256(p.roundsPlayed).toString()),
                "]"
            );
    }

    /// @param value already JSON-encoded (quoted string or bare number)
    function _attr(string memory traitType, string memory value) private pure returns (string memory) {
        return string.concat('{"trait_type":"', traitType, '","value":', value, "}");
    }
}
