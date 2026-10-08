// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {IResultsRegistry} from "../../contracts/interfaces/IResultsRegistry.sol";
import {Predictions} from "../../contracts/Predictions.sol";
import {ResultsRegistry} from "../../contracts/ResultsRegistry.sol";

/// @dev Deploys both contracts with separate role holders and offers helpers for fixtures,
///      results and signed submissions.
abstract contract M2Base is Test {
    ResultsRegistry internal registry;
    Predictions internal predictions;

    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal resultsRelayer = makeAddr("resultsRelayer");
    address internal submitter = makeAddr("submitter");
    address internal steward = makeAddr("steward");
    address internal stranger = makeAddr("stranger");

    address internal alice;
    uint256 internal aliceKey;
    address internal bob;
    uint256 internal bobKey;
    address internal carol;
    uint256 internal carolKey;

    uint64 internal constant POSTPONE = 7 days;
    uint64 internal constant FINALIZATION_DELAY = 24 hours;
    uint64 internal constant T0 = 1_800_000_000;

    bytes32 internal constant LEAGUE = keccak256("mvl-2026-27-main");

    /// @dev Volleyball, best of 5: the winner is the first to 3 sets.
    uint8 internal constant VOLLEYBALL_SETS = 3;

    uint256 private _nextGame;

    function setUp() public virtual {
        vm.warp(T0);
        registry = new ResultsRegistry(0, admin, POSTPONE, operator, resultsRelayer, steward);
        predictions = new Predictions(0, admin, registry, operator, submitter, steward, FINALIZATION_DELAY);

        (alice, aliceKey) = makeAddrAndKey("alice");
        (bob, bobKey) = makeAddrAndKey("bob");
        (carol, carolKey) = makeAddrAndKey("carol");
    }

    // --- fixtures ----------------------------------------------------------

    function _gameId(uint256 n) internal pure returns (bytes32) {
        return keccak256(bytes(string.concat("mvl-2026-27-", vm.toString(n))));
    }

    function _homeTeam(uint256 n) internal pure returns (bytes32) {
        return keccak256(abi.encode("home", n));
    }

    function _awayTeam(uint256 n) internal pure returns (bytes32) {
        return keccak256(abi.encode("away", n));
    }

    /// @dev Registers `count` new volleyball games starting at `startTime`.
    function _registerGames(uint256 count, uint64 startTime) internal returns (bytes32[] memory ids) {
        return _registerGames(count, startTime, VOLLEYBALL_SETS, false);
    }

    /// @dev Registers `count` new games starting at `startTime`, in the given format.
    function _registerGames(
        uint256 count,
        uint64 startTime,
        uint8 targetScore,
        bool drawAllowed
    ) internal returns (bytes32[] memory ids) {
        ids = new bytes32[](count);
        IResultsRegistry.GameInfo[] memory infos = new IResultsRegistry.GameInfo[](count);
        for (uint256 i = 0; i < count; ++i) {
            uint256 n = ++_nextGame;
            ids[i] = _gameId(n);
            infos[i] = IResultsRegistry.GameInfo(
                ids[i],
                _homeTeam(n),
                _awayTeam(n),
                startTime,
                targetScore,
                drawAllowed
            );
        }
        vm.prank(operator);
        registry.registerGames(infos);
    }

    function _createLeague() internal {
        vm.prank(operator);
        predictions.createLeague(LEAGUE, keccak256("metadata"));
    }

    function _scheduleRound(
        uint16 matchday,
        bytes32[] memory ids,
        uint64 opensAt,
        uint64 lockTime
    ) internal returns (bytes32 roundId) {
        vm.prank(operator);
        roundId = predictions.scheduleRound(LEAGUE, matchday, opensAt, lockTime, ids);
    }

    // --- results -----------------------------------------------------------

    function _result(
        bytes32 gameId,
        IResultsRegistry.GameStatus status,
        IResultsRegistry.Side winner,
        uint16 homeScore,
        uint16 awayScore
    ) internal view returns (IResultsRegistry.ResultInput memory r) {
        IResultsRegistry.Game memory g = registry.getGame(gameId);
        r = IResultsRegistry.ResultInput({
            gameId: gameId,
            homeTeam: g.homeTeam,
            awayTeam: g.awayTeam,
            status: status,
            winner: winner,
            homeScore: homeScore,
            awayScore: awayScore,
            extraPeriods: 0,
            sourceHash: sha256(abi.encode(gameId, homeScore, awayScore)),
            attestationId: "mvl_2026_game-0001"
        });
    }

    /// @dev A valid final result for the game's format: N-(N-1) / 0-N in a race to N sets
    ///      (volleyball: 3-2 / 0-3), 88-80 / 75-91 with an open score.
    function _final(bytes32 gameId, bool homeWins) internal view returns (IResultsRegistry.ResultInput memory) {
        uint16 target = registry.getGame(gameId).targetScore;
        if (target != 0) {
            return
                homeWins
                    ? _result(gameId, IResultsRegistry.GameStatus.Final, IResultsRegistry.Side.Home, target, target - 1)
                    : _result(gameId, IResultsRegistry.GameStatus.Final, IResultsRegistry.Side.Away, 0, target);
        }
        return
            homeWins
                ? _result(gameId, IResultsRegistry.GameStatus.Final, IResultsRegistry.Side.Home, 88, 80)
                : _result(gameId, IResultsRegistry.GameStatus.Final, IResultsRegistry.Side.Away, 75, 91);
    }

    /// @dev A 1-1 draw (valid only on games registered with `drawAllowed`).
    function _draw(bytes32 gameId) internal view returns (IResultsRegistry.ResultInput memory) {
        return _result(gameId, IResultsRegistry.GameStatus.Final, IResultsRegistry.Side.Draw, 1, 1);
    }

    function _record(IResultsRegistry.ResultInput memory r) internal {
        IResultsRegistry.ResultInput[] memory batch = new IResultsRegistry.ResultInput[](1);
        batch[0] = r;
        vm.prank(resultsRelayer);
        registry.recordResults(batch);
    }

    /// @dev Records final results for all games (true = home wins); they are final right away.
    function _settleGames(bytes32[] memory ids, bool[] memory homeWins) internal {
        IResultsRegistry.ResultInput[] memory batch = new IResultsRegistry.ResultInput[](ids.length);
        for (uint256 i = 0; i < ids.length; ++i) batch[i] = _final(ids[i], homeWins[i]);
        vm.prank(resultsRelayer);
        registry.recordResults(batch);
    }

    /// @dev Waits out the finalization delay, then settles the round (permissionless).
    function _finalizeRound(bytes32 roundId) internal {
        uint64 readyAt = predictions.finalizableAt(roundId);
        if (block.timestamp < readyAt) vm.warp(readyAt);
        predictions.finalizeRound(roundId);
    }

    // --- predictions -------------------------------------------------------

    function _picks(uint8 a, uint8 b, uint8 c) internal pure returns (bytes memory) {
        return abi.encodePacked(a, b, c);
    }

    function _sign(
        uint256 key,
        address user,
        bytes32 roundId,
        bytes32 picksHash,
        uint64 confirmedAt
    ) internal view returns (bytes memory) {
        bytes32 digest = predictions.submissionDigest(user, roundId, picksHash, confirmedAt);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _item(
        uint256 key,
        address user,
        bytes32 roundId,
        bytes memory picks,
        uint64 confirmedAt
    ) internal view returns (Predictions.BatchItem memory it) {
        bytes32 picksHash = predictions.computePicksHash(roundId, picks);
        it = Predictions.BatchItem({
            user: user,
            picksHash: picksHash,
            picks: picks,
            confirmedAt: confirmedAt,
            signature: _sign(key, user, roundId, picksHash, confirmedAt)
        });
    }

    function _submit(uint256 key, address user, bytes32 roundId, bytes memory picks) internal {
        Predictions.BatchItem memory it = _item(key, user, roundId, picks, uint64(block.timestamp));
        vm.prank(submitter);
        predictions.submitFor(it.user, roundId, it.picksHash, it.picks, it.confirmedAt, it.signature);
    }

    function _bools(bool a, bool b, bool c) internal pure returns (bool[] memory r) {
        r = new bool[](3);
        (r[0], r[1], r[2]) = (a, b, c);
    }
}
