// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControlDefaultAdminRules} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IERC5192} from "./interfaces/IERC5192.sol";
import {IPredictions} from "./interfaces/IPredictions.sol";
import {BadgeSVG} from "./libraries/BadgeSVG.sol";

/// @title LeagueBadge
/// @notice Soulbound (ERC-5192) badge with a player's final standing in a completed league.
///         Claimed on the user's request by our minter (we pay the gas) once the league's
///         challenge window is over. Stats are proven twice: by a Merkle proof against the
///         standings root anchored in Predictions, and by recomputing them on-chain.
contract LeagueBadge is ERC721, IERC5192, AccessControlDefaultAdminRules, Pausable {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    uint256 public constant MAX_DISPLAY_TEXT_LENGTH = 64;

    IPredictions public immutable predictions;

    struct BadgeStats {
        uint32 rank;
        uint32 points;
        uint32 correct;
        uint32 counted;
        uint16 roundsPlayed;
    }

    struct Badge {
        bytes32 leagueId;
        uint64 mintedAt;
        uint32 totalPlayers;
        BadgeStats stats;
    }

    struct LeagueDisplay {
        string name;
        string season;
    }

    mapping(uint256 tokenId => Badge) private _badges;
    mapping(bytes32 leagueId => LeagueDisplay) private _displays;

    error ZeroAddress();
    error ClaimsNotOpen(bytes32 leagueId);
    error AlreadyClaimed(uint256 tokenId);
    error InvalidProof();
    error StatsMismatch();
    error Soulbound();
    error InvalidDisplayText();

    event BadgeClaimed(uint256 indexed tokenId, bytes32 indexed leagueId, address indexed account, BadgeStats stats);
    event LeagueDisplaySet(bytes32 indexed leagueId, string name, string season);

    constructor(
        uint48 adminDelay,
        address admin,
        IPredictions predictions_
    ) ERC721("M2 League Badge", "M2BADGE") AccessControlDefaultAdminRules(adminDelay, admin) {
        if (address(predictions_) == address(0)) revert ZeroAddress();
        predictions = predictions_;
    }

    // ---------------------------------------------------------------------
    // Minter
    // ---------------------------------------------------------------------

    function claim(
        bytes32 leagueId,
        address account,
        BadgeStats calldata stats,
        bytes32[] calldata proof
    ) external onlyRole(MINTER_ROLE) whenNotPaused returns (uint256 tokenId) {
        if (account == address(0)) revert ZeroAddress();
        IPredictions.League memory league = predictions.getLeague(leagueId);
        if (!league.finalized || block.timestamp < league.claimsOpenAt) revert ClaimsNotOpen(leagueId);

        tokenId = tokenIdOf(leagueId, account);
        if (_ownerOf(tokenId) != address(0)) revert AlreadyClaimed(tokenId);
        if (!MerkleProof.verifyCalldata(proof, league.standingsRoot, leafOf(leagueId, account, stats))) {
            revert InvalidProof();
        }
        IPredictions.LeagueStats memory onchain = predictions.leagueStatsOf(leagueId, account);
        if (
            onchain.points != stats.points ||
            onchain.correct != stats.correct ||
            onchain.counted != stats.counted ||
            onchain.roundsPlayed != stats.roundsPlayed
        ) revert StatsMismatch();

        _badges[tokenId] = Badge({
            leagueId: leagueId,
            mintedAt: uint64(block.timestamp),
            totalPlayers: league.totalPlayers,
            stats: stats
        });
        _mint(account, tokenId);
        emit Locked(tokenId);
        emit BadgeClaimed(tokenId, leagueId, account, stats);
    }

    // ---------------------------------------------------------------------
    // Operator
    // ---------------------------------------------------------------------

    /// @notice Name and season shown in the on-chain artwork. UTF-8 (Cyrillic ok), no JSON/SVG
    ///         metacharacters.
    function setLeagueDisplay(
        bytes32 leagueId,
        string calldata name,
        string calldata season
    ) external onlyRole(OPERATOR_ROLE) {
        _checkDisplayText(name);
        _checkDisplayText(season);
        _displays[leagueId] = LeagueDisplay(name, season);
        emit LeagueDisplaySet(leagueId, name, season);
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function tokenIdOf(bytes32 leagueId, address account) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(leagueId, account)));
    }

    /// @notice OZ StandardMerkleTree leaf:
    ///         (bytes32 leagueId, address account, uint32 rank, uint32 points, uint32 correct,
    ///          uint32 counted, uint16 roundsPlayed)
    function leafOf(bytes32 leagueId, address account, BadgeStats calldata s) public pure returns (bytes32) {
        return
            keccak256(
                bytes.concat(
                    keccak256(abi.encode(leagueId, account, s.rank, s.points, s.correct, s.counted, s.roundsPlayed))
                )
            );
    }

    function getBadge(uint256 tokenId) external view returns (Badge memory) {
        _requireOwned(tokenId);
        return _badges[tokenId];
    }

    function getLeagueDisplay(bytes32 leagueId) external view returns (LeagueDisplay memory) {
        return _displays[leagueId];
    }

    function locked(uint256 tokenId) external view returns (bool) {
        _requireOwned(tokenId);
        return true;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        Badge storage b = _badges[tokenId];
        LeagueDisplay storage d = _displays[b.leagueId];
        return
            BadgeSVG.tokenURI(
                BadgeSVG.Params({
                    tokenId: tokenId,
                    leagueName: bytes(d.name).length == 0 ? "M2 League" : d.name,
                    season: d.season,
                    rank: b.stats.rank,
                    totalPlayers: b.totalPlayers,
                    points: b.stats.points,
                    correct: b.stats.correct,
                    counted: b.stats.counted,
                    roundsPlayed: b.stats.roundsPlayed
                })
            );
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721, AccessControlDefaultAdminRules) returns (bool) {
        return interfaceId == type(IERC5192).interfaceId || super.supportsInterface(interfaceId);
    }

    // ---------------------------------------------------------------------
    // Soulbound: no transfers, no approvals
    // ---------------------------------------------------------------------

    function approve(address, uint256) public pure override {
        revert Soulbound();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert Soulbound();
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (_ownerOf(tokenId) != address(0)) revert Soulbound(); // only mints (from == 0) are allowed
        return super._update(to, tokenId, auth);
    }

    function _checkDisplayText(string calldata text) private pure {
        bytes calldata b = bytes(text);
        if (b.length == 0 || b.length > MAX_DISPLAY_TEXT_LENGTH) revert InvalidDisplayText();
        for (uint256 i = 0; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c < 0x20 || c == '"' || c == "&" || c == "<" || c == ">" || c == "\\") revert InvalidDisplayText();
        }
    }
}
