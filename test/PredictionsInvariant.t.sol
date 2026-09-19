// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {IResultsRegistry} from "../contracts/interfaces/IResultsRegistry.sol";
import {Predictions} from "../contracts/Predictions.sol";
import {ResultsRegistry} from "../contracts/ResultsRegistry.sol";
import {M2Base} from "./utils/M2Base.sol";

/// @dev Drives random sequences of submissions (valid or not), time jumps, results and
///      finalization against a single 3-game round.
contract PredictionsHandler is Test {
    Predictions internal immutable predictions;
    ResultsRegistry internal immutable registry;
    address internal immutable submitter;
    address internal immutable resultsRelayer;
    bytes32 internal immutable roundId;
    uint64 internal immutable opensAt;
    uint64 internal immutable lockTime;

    bytes32[] internal games;
    address[] public users;
    uint256[] internal keys;

    mapping(address => bytes) public storedPicks;
    mapping(address => uint64) public storedConfirmedAt;
    uint256 public accepted;
    bool public resultsRecorded;

    constructor(
        Predictions predictions_,
        ResultsRegistry registry_,
        address submitter_,
        address resultsRelayer_,
        bytes32 roundId_,
        bytes32[] memory games_
    ) {
        predictions = predictions_;
        registry = registry_;
        submitter = submitter_;
        resultsRelayer = resultsRelayer_;
        roundId = roundId_;
        games = games_;
        Predictions.Round memory r = predictions_.getRound(roundId_);
        opensAt = r.opensAt;
        lockTime = r.lockTime;
        for (uint256 i = 0; i < 5; ++i) {
            (address user, uint256 key) = makeAddrAndKey(string.concat("player", vm.toString(i)));
            users.push(user);
            keys.push(key);
        }
    }

    function usersLength() external view returns (uint256) {
        return users.length;
    }

    function submit(uint256 userSeed, uint8 pickBits, uint32 age, bool wrongKey) external {
        if (block.timestamp >= lockTime) return;
        uint256 u = userSeed % users.length;
        address user = users[u];

        bytes memory picks = new bytes(3);
        for (uint256 i = 0; i < 3; ++i) picks[i] = bytes1((pickBits >> i) & 1 == 1 ? uint8(1) : uint8(2));
        uint64 confirmedAt = uint64(block.timestamp) - uint64(age % 1 hours);
        if (confirmedAt < opensAt) confirmedAt = opensAt;

        bytes32 picksHash = predictions.computePicksHash(roundId, picks);
        bytes32 digest = predictions.submissionDigest(user, roundId, picksHash, confirmedAt);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey ? keys[(u + 1) % keys.length] : keys[u], digest);

        Predictions.BatchItem[] memory items = new Predictions.BatchItem[](1);
        items[0] = Predictions.BatchItem(user, picksHash, picks, confirmedAt, abi.encodePacked(r, s, v));
        vm.prank(submitter);
        Predictions.SubmitStatus[] memory statuses = predictions.submitForBatch(roundId, items);

        if (statuses[0] == Predictions.SubmitStatus.Ok) {
            storedPicks[user] = picks;
            storedConfirmedAt[user] = confirmedAt;
            ++accepted;
        }
    }

    function advance(uint32 dt) external {
        vm.warp(block.timestamp + (dt % 12 hours));
    }

    function recordResults(uint8 winBits, uint8 voidBits) external {
        if (resultsRecorded || block.timestamp < lockTime) return;
        IResultsRegistry.ResultInput[] memory batch = new IResultsRegistry.ResultInput[](3);
        for (uint256 i = 0; i < 3; ++i) {
            IResultsRegistry.Game memory g = registry.getGame(games[i]);
            bool isVoid = (voidBits >> i) & 1 == 1;
            bool homeWins = (winBits >> i) & 1 == 1;
            batch[i] = IResultsRegistry.ResultInput({
                gameId: games[i],
                homeTeam: g.homeTeam,
                awayTeam: g.awayTeam,
                status: isVoid ? IResultsRegistry.GameStatus.Void : IResultsRegistry.GameStatus.Final,
                winner: isVoid ? IResultsRegistry.Side.None : (homeWins ? IResultsRegistry.Side.Home : IResultsRegistry.Side.Away),
                homeScore: isVoid ? 0 : (homeWins ? 90 : 80),
                awayScore: isVoid ? 0 : (homeWins ? 80 : 90),
                overtimes: 0,
                sourceHash: keccak256(abi.encode(i)),
                attestationId: "invariant"
            });
        }
        vm.prank(resultsRelayer);
        registry.recordResults(batch);
        resultsRecorded = true;
    }

    function finalize() external {
        if (!resultsRecorded) return;
        for (uint256 i = 0; i < 3; ++i) if (!registry.isFinal(games[i])) return;
        if (predictions.getRound(roundId).state != Predictions.RoundState.Scheduled) return;
        predictions.finalizeRound(roundId);
    }
}

contract PredictionsInvariantTest is M2Base {
    PredictionsHandler internal handler;
    bytes32 internal roundId;
    uint64 internal lockTime;

    function setUp() public override {
        super.setUp();
        _createLeague();
        lockTime = T0 + 1 days;
        bytes32[] memory games = _registerGames(3, lockTime);
        roundId = _scheduleRound(1, games, T0, lockTime);

        handler = new PredictionsHandler(predictions, registry, submitter, resultsRelayer, roundId, games);
        targetContract(address(handler));
    }

    /// Stored predictions never change and always match what was accepted.
    function invariant_EntriesAreImmutable() public view {
        for (uint256 i = 0; i < handler.usersLength(); ++i) {
            address user = handler.users(i);
            (uint64 confirmedAt, uint64 submittedAt, bytes memory picks) = predictions.getEntry(roundId, user);
            assertEq(picks, handler.storedPicks(user));
            assertEq(confirmedAt, handler.storedConfirmedAt(user));
            if (submittedAt != 0) {
                assertLt(submittedAt, lockTime, "stored after lock");
                assertLt(confirmedAt, lockTime, "confirmed after lock");
            }
        }
    }

    /// One submission per user: the counter equals the number of accepted items.
    function invariant_OneSubmissionPerUser() public view {
        assertEq(predictions.getRound(roundId).submissions, handler.accepted());
        assertLe(handler.accepted(), handler.usersLength());
    }

    /// Layer-0 scores are bounded.
    function invariant_ScoresAreBounded() public view {
        for (uint256 i = 0; i < handler.usersLength(); ++i) {
            (uint8 correct, uint8 counted) = predictions.scoreOf(roundId, handler.users(i));
            assertLe(correct, counted);
            assertLe(counted, 3);
        }
    }
}
