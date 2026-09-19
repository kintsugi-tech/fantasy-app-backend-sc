// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";

import {IPredictions} from "../contracts/interfaces/IPredictions.sol";
import {LeagueBadge} from "../contracts/LeagueBadge.sol";
import {M2Base} from "./utils/M2Base.sol";

contract LeagueBadgeTest is M2Base {
    bytes32[] internal games;
    LeagueBadge.BadgeStats internal aliceStats;
    LeagueBadge.BadgeStats internal bobStats;

    function setUp() public override {
        super.setUp();
        _createLeague();
        uint64 lockTime = T0 + 2 days;
        games = _registerGames(3, lockTime);
        bytes32 roundId = _scheduleRound(1, games, T0, lockTime);

        vm.warp(T0 + 1 hours);
        _submit(aliceKey, alice, roundId, _picks(1, 2, 1));
        _submit(bobKey, bob, roundId, _picks(2, 2, 2));

        vm.warp(lockTime + 3 hours);
        _settleGames(games, _bools(true, false, true)); // alice 3/3, bob 1/3
        predictions.finalizeRound(roundId);

        aliceStats = _statsOf(alice, 1);
        bobStats = _statsOf(bob, 2);
    }

    // --- claim -----------------------------------------------------------------

    function test_ClaimMintsSoulboundBadge() public {
        (bytes32 root, bytes32 aliceLeaf, bytes32 bobLeaf) = _tree(aliceStats, bobStats);
        _finalizeLeague(root);
        vm.warp(block.timestamp + CHALLENGE);

        uint256 tokenId = badge.tokenIdOf(LEAGUE, alice);
        bytes32[] memory proof = _proof(bobLeaf);
        vm.expectEmit(address(badge));
        emit LeagueBadge.BadgeClaimed(tokenId, LEAGUE, alice, aliceStats);
        vm.prank(minter);
        badge.claim(LEAGUE, alice, aliceStats, proof);

        assertEq(badge.ownerOf(tokenId), alice);
        assertTrue(badge.locked(tokenId));
        LeagueBadge.Badge memory b = badge.getBadge(tokenId);
        assertEq(b.leagueId, LEAGUE);
        assertEq(b.totalPlayers, 2);
        assertEq(b.stats.points, 3);
        assertEq(b.stats.rank, 1);

        vm.prank(minter);
        badge.claim(LEAGUE, bob, bobStats, _proof(aliceLeaf));
        assertEq(badge.balanceOf(bob), 1);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(LeagueBadge.AlreadyClaimed.selector, tokenId));
        badge.claim(LEAGUE, alice, aliceStats, proof);
    }

    function test_ClaimWaitsForChallengeWindow() public {
        (bytes32 root, , bytes32 bobLeaf) = _tree(aliceStats, bobStats);
        bytes32[] memory proof = _proof(bobLeaf);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(LeagueBadge.ClaimsNotOpen.selector, LEAGUE));
        badge.claim(LEAGUE, alice, aliceStats, proof); // league not finalized

        _finalizeLeague(root);
        vm.warp(block.timestamp + CHALLENGE - 1);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(LeagueBadge.ClaimsNotOpen.selector, LEAGUE));
        badge.claim(LEAGUE, alice, aliceStats, proof);
    }

    function test_ClaimRejectsWrongProof() public {
        (bytes32 root, , bytes32 bobLeaf) = _tree(aliceStats, bobStats);
        _finalizeLeague(root);
        vm.warp(block.timestamp + CHALLENGE);

        LeagueBadge.BadgeStats memory better = aliceStats;
        better.rank = 0;
        bytes32[] memory proof = _proof(bobLeaf);
        vm.prank(minter);
        vm.expectRevert(LeagueBadge.InvalidProof.selector);
        badge.claim(LEAGUE, alice, better, proof);
    }

    /// @dev Even a standings root with inflated stats (off-chain bug) cannot mint them.
    function test_ClaimRejectsStatsThatDoNotMatchChain() public {
        LeagueBadge.BadgeStats memory inflated = bobStats;
        inflated.points = 3;
        inflated.correct = 3;
        (bytes32 root, bytes32 aliceLeaf, ) = _tree(aliceStats, inflated);
        _finalizeLeague(root);
        vm.warp(block.timestamp + CHALLENGE);

        bytes32[] memory proof = _proof(aliceLeaf);
        vm.prank(minter);
        vm.expectRevert(LeagueBadge.StatsMismatch.selector);
        badge.claim(LEAGUE, bob, inflated, proof);
    }

    function test_ClaimOnlyMinter() public {
        (bytes32 root, , bytes32 bobLeaf) = _tree(aliceStats, bobStats);
        _finalizeLeague(root);
        vm.warp(block.timestamp + CHALLENGE);
        bytes32 role = badge.MINTER_ROLE();
        bytes32[] memory proof = _proof(bobLeaf);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        badge.claim(LEAGUE, alice, aliceStats, proof);
    }

    // --- soulbound -------------------------------------------------------------

    function test_BadgeCannotMove() public {
        uint256 tokenId = _claimAlice();

        vm.startPrank(alice);
        vm.expectRevert(LeagueBadge.Soulbound.selector);
        badge.transferFrom(alice, bob, tokenId);
        vm.expectRevert(LeagueBadge.Soulbound.selector);
        badge.safeTransferFrom(alice, bob, tokenId);
        vm.expectRevert(LeagueBadge.Soulbound.selector);
        badge.approve(bob, tokenId);
        vm.expectRevert(LeagueBadge.Soulbound.selector);
        badge.setApprovalForAll(bob, true);
        vm.stopPrank();

        assertEq(badge.ownerOf(tokenId), alice);
        // No display text set for this league: metadata still renders with a fallback name.
        assertEq(_prefix(badge.tokenURI(tokenId), 29), "data:application/json;base64,");
    }

    function test_SupportsInterfaces() public view {
        assertTrue(badge.supportsInterface(0xb45a3c0e)); // ERC-5192
        assertTrue(badge.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(badge.supportsInterface(0x5b5e139f)); // ERC-721 metadata
        assertTrue(badge.supportsInterface(0x7965db0b)); // AccessControl
        assertFalse(badge.supportsInterface(0xffffffff));
    }

    // --- metadata --------------------------------------------------------------

    function test_TokenURIIsOnChainJson() public {
        vm.prank(operator);
        badge.setLeagueDisplay(LEAGUE, unicode"Монгол Сагсан Бөмбөг", "2026-27");
        uint256 tokenId = _claimAlice();
        string memory uri = badge.tokenURI(tokenId);
        assertEq(_prefix(uri, 29), "data:application/json;base64,");
    }

    function test_LeagueDisplayRejectsMetacharacters() public {
        string[6] memory bad = ['a"b', "a<b", "a>b", "a&b", "a\\b", "a\nb"];
        for (uint256 i = 0; i < bad.length; ++i) {
            vm.prank(operator);
            vm.expectRevert(LeagueBadge.InvalidDisplayText.selector);
            badge.setLeagueDisplay(LEAGUE, bad[i], "2026-27");
        }
        vm.prank(operator);
        vm.expectRevert(LeagueBadge.InvalidDisplayText.selector);
        badge.setLeagueDisplay(LEAGUE, "", "2026-27");
    }

    // --- helpers ---------------------------------------------------------------

    function _statsOf(address user, uint32 rank) internal view returns (LeagueBadge.BadgeStats memory) {
        IPredictions.LeagueStats memory s = predictions.leagueStatsOf(LEAGUE, user);
        return LeagueBadge.BadgeStats(rank, s.points, s.correct, s.counted, s.roundsPlayed);
    }

    function _leaf(address account, LeagueBadge.BadgeStats memory s) internal pure returns (bytes32) {
        return
            keccak256(
                bytes.concat(
                    keccak256(abi.encode(LEAGUE, account, s.rank, s.points, s.correct, s.counted, s.roundsPlayed))
                )
            );
    }

    /// @dev Two-leaf tree: each leaf's proof is the other leaf.
    function _tree(
        LeagueBadge.BadgeStats memory a,
        LeagueBadge.BadgeStats memory b
    ) internal view returns (bytes32 root, bytes32 aliceLeaf, bytes32 bobLeaf) {
        aliceLeaf = _leaf(alice, a);
        bobLeaf = _leaf(bob, b);
        root = Hashes.commutativeKeccak256(aliceLeaf, bobLeaf);
    }

    function _proof(bytes32 sibling) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = sibling;
    }

    function _finalizeLeague(bytes32 root) internal {
        vm.prank(steward);
        predictions.finalizeLeague(LEAGUE, root, 2, keccak256("report"), "https://m2.example/report.json");
    }

    function _claimAlice() internal returns (uint256 tokenId) {
        (bytes32 root, , bytes32 bobLeaf) = _tree(aliceStats, bobStats);
        _finalizeLeague(root);
        vm.warp(block.timestamp + CHALLENGE);
        vm.prank(minter);
        tokenId = badge.claim(LEAGUE, alice, aliceStats, _proof(bobLeaf));
    }

    function _prefix(string memory s, uint256 n) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(n);
        for (uint256 i = 0; i < n; ++i) out[i] = b[i];
        return string(out);
    }
}
