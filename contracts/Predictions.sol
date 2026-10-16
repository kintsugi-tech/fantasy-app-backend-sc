// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControlDefaultAdminRules} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IPredictions} from "./interfaces/IPredictions.sol";
import {IResultsRegistry} from "./interfaces/IResultsRegistry.sol";
import {PicksLib} from "./libraries/PicksLib.sol";

/// @title Predictions
/// @notice Leagues, rounds (matchdays) and users' predictions.
///
///         - One submission per user per round, immutable once stored.
///         - Users never send transactions: at "Confirm" the app signs an EIP-712 `Submission`
///           with the user's (custodial) key and our relayer submits it, paying the gas.
///         - Picks are stored in clear, so the layer-0 score of any user is recomputable on-chain
///           (`scoreOf`, `leagueStatsOf`) from these picks and the ResultsRegistry outcomes.
///         - A round settles `finalizationDelay` after its last result, and never while one of its
///           results can still be corrected (ResultsRegistry.correctableUntil). In that window the
///           steward corrects a wrong result, or cancels the round as a last resort.
///         - Final standings, a Merkle root, are proposed by the steward after the last round
///           (`proposeStandings`, replaceable) and anchored once 48 h later (`finalizeLeague`).
///           Once proposed, the league takes no new round, unless the admin withdraws the
///           proposal (`withdrawStandings`, for one made too early).
///           Anyone can check a row against them and against the chain (`checkStanding`).
///         - Pause: the steward stops everything but `cancelRound` in minutes; only the admin
///           (cold wallet) resumes.
contract Predictions is IPredictions, AccessControlDefaultAdminRules, Pausable, EIP712 {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant SUBMITTER_ROLE = keccak256("SUBMITTER_ROLE");
    bytes32 public constant STEWARD_ROLE = keccak256("STEWARD_ROLE");

    bytes32 public constant SUBMISSION_TYPEHASH =
        keccak256("Submission(address user,bytes32 roundId,bytes32 picksHash,uint64 confirmedAt)");

    uint256 public constant MAX_GAMES = 32; // picks and outcomes are packed 2 bits/game in a uint64
    uint256 public constant MAX_ROUNDS_PER_LEAGUE = 64;
    uint256 public constant MAX_BATCH = 100;
    uint64 public constant MAX_CLOCK_SKEW = 60;
    uint64 public constant MIN_LOCK_NOTICE = 15 minutes; // > MAX_CLOCK_SKEW, see updateRoundLock
    uint64 public constant MIN_FINALIZATION_DELAY = 1 hours;
    uint64 public constant MAX_FINALIZATION_DELAY = 7 days;
    uint64 public constant STANDINGS_REVIEW_PERIOD = 48 hours;

    IResultsRegistry public immutable registry;

    /// @notice Time after a round's last recorded result before it can be finalized (default 24 h).
    uint64 public finalizationDelay;

    enum RoundState {
        None,
        Scheduled,
        Cancelled,
        Finalized
    }

    enum SubmitStatus {
        Ok,
        Duplicate,
        InvalidUser,
        InvalidPicks,
        PicksHashMismatch,
        InvalidConfirmedAt,
        InvalidSignature
    }

    struct Round {
        bytes32 leagueId;
        bytes32 gamesHash; // keccak256(abi.encodePacked(gameIds))
        uint64 opensAt;
        uint64 lockTime;
        uint16 matchday;
        uint8 gameCount;
        RoundState state;
        uint32 submissions;
        uint64 outcomes; // set by finalizeRound: 2 bits/game, 0 = not counted, 1 = home, 2 = away, 3 = draw
    }

    struct Entry {
        uint64 confirmedAt; // signed by the user: when they pressed "Confirm"
        uint64 submittedAt; // block time of the relayer's tx
        uint64 packedPicks;
    }

    struct BatchItem {
        address user;
        bytes32 picksHash;
        bytes picks;
        uint64 confirmedAt;
        bytes signature;
    }

    mapping(bytes32 leagueId => League) private _leagues;
    mapping(bytes32 leagueId => bytes32[]) private _leagueRounds;
    mapping(bytes32 roundId => Round) private _rounds;
    mapping(bytes32 roundId => bytes32[]) private _roundGames;
    mapping(bytes32 roundId => mapping(address user => Entry)) private _entries;
    mapping(bytes32 leagueId => StandingsProposal) private _proposals;

    error ZeroAddress();
    error InvalidLeague(bytes32 leagueId);
    error LeagueExists(bytes32 leagueId);
    error LeagueNotActive(bytes32 leagueId);
    error TooManyRounds(bytes32 leagueId);
    error RoundExists(bytes32 roundId);
    error InvalidSchedule();
    error InvalidGameCount(uint256 count);
    error DuplicateGame(bytes32 gameId);
    error GameNotSchedulable(bytes32 gameId);
    error LockAfterStart(bytes32 gameId);
    error RoundNotActive(bytes32 roundId);
    error RoundNotOpen(bytes32 roundId);
    error RoundLocked(bytes32 roundId);
    error RoundNotLocked(bytes32 roundId);
    error NoResult(bytes32 gameId);
    error FinalizationPending(bytes32 roundId, uint64 finalizableAt);
    error DelayOutOfRange(uint64 value);
    error RoundsPending(bytes32 leagueId);
    error InvalidStandings();
    error NoStandingsProposal(bytes32 leagueId);
    error ReviewPeriodOpen(bytes32 leagueId, uint64 finalizableAt);
    error StandingsOutdated(bytes32 leagueId);
    error StandingsAlreadyProposed(bytes32 leagueId);
    error EmptyBatch();
    error BatchTooLarge(uint256 size, uint256 max);
    error SubmissionRejected(address user, SubmitStatus status);

    event LeagueCreated(bytes32 indexed leagueId, bytes32 metadataHash);
    event RoundScheduled(
        bytes32 indexed roundId,
        bytes32 indexed leagueId,
        uint16 matchday,
        uint64 opensAt,
        uint64 lockTime,
        bytes32 gamesHash,
        bytes32[] gameIds
    );
    event RoundLockUpdated(bytes32 indexed roundId, uint64 oldLockTime, uint64 newLockTime);
    event RoundCancelled(bytes32 indexed roundId, string reason);
    event PredictionSubmitted(
        bytes32 indexed roundId,
        address indexed user,
        bytes32 picksHash,
        bytes picks,
        uint64 confirmedAt
    );
    event SubmissionSkipped(bytes32 indexed roundId, address indexed user, SubmitStatus status);
    event RoundFinalized(bytes32 indexed roundId, uint64 outcomes, uint8 countedGames);
    event FinalizationDelaySet(uint64 finalizationDelay);
    event StandingsProposed(
        bytes32 indexed leagueId,
        bytes32 standingsRoot,
        uint32 totalPlayers,
        bytes32 reportHash,
        string reportURI,
        uint64 finalizableAt
    );
    event StandingsWithdrawn(bytes32 indexed leagueId);
    event LeagueFinalized(bytes32 indexed leagueId, bytes32 standingsRoot, uint32 totalPlayers, bytes32 reportHash);

    /// @dev Every role holder is set here, so the deployer gets no role: any account can deploy.
    constructor(
        uint48 adminDelay,
        address admin,
        IResultsRegistry registry_,
        address operator,
        address submitter,
        address steward,
        uint64 initialFinalizationDelay
    ) AccessControlDefaultAdminRules(adminDelay, admin) EIP712("M2Predictions", "1") {
        if (
            address(registry_) == address(0) ||
            operator == address(0) ||
            submitter == address(0) ||
            steward == address(0)
        ) revert ZeroAddress();
        registry = registry_;
        _grantRole(OPERATOR_ROLE, operator);
        _grantRole(SUBMITTER_ROLE, submitter);
        _grantRole(STEWARD_ROLE, steward);
        _setFinalizationDelay(initialFinalizationDelay);
    }

    // ---------------------------------------------------------------------
    // Operator: leagues and rounds
    // ---------------------------------------------------------------------

    /// @param leagueId keccak256(bytes(slug))
    /// @param metadataHash hash of the off-chain league metadata (rules, sponsor, prizes)
    function createLeague(bytes32 leagueId, bytes32 metadataHash) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        if (leagueId == bytes32(0)) revert InvalidLeague(leagueId);
        League storage l = _leagues[leagueId];
        if (l.exists) revert LeagueExists(leagueId);
        l.exists = true;
        l.metadataHash = metadataHash;
        emit LeagueCreated(leagueId, metadataHash);
    }

    /// @notice Schedule a round. Its game list is immutable and its id is never reused, so a
    ///         signature for a round can never be replayed onto different games.
    /// @dev All games must be registered in the ResultsRegistry, without a result, and must not
    ///      start before `lockTime`. No round once the league's standings are proposed.
    function scheduleRound(
        bytes32 leagueId,
        uint16 matchday,
        uint64 opensAt,
        uint64 lockTime,
        bytes32[] calldata gameIds
    ) external onlyRole(OPERATOR_ROLE) whenNotPaused returns (bytes32 roundId) {
        League storage l = _leagues[leagueId];
        if (!l.exists || l.finalized) revert LeagueNotActive(leagueId);
        if (_proposals[leagueId].proposedAt != 0) revert StandingsAlreadyProposed(leagueId);
        if (l.roundCount >= MAX_ROUNDS_PER_LEAGUE) revert TooManyRounds(leagueId);
        roundId = roundIdOf(leagueId, matchday);
        if (_rounds[roundId].state != RoundState.None) revert RoundExists(roundId);
        if (gameIds.length == 0 || gameIds.length > MAX_GAMES) revert InvalidGameCount(gameIds.length);
        if (opensAt >= lockTime || lockTime <= block.timestamp) revert InvalidSchedule();

        for (uint256 i = 0; i < gameIds.length; ++i) {
            bytes32 gameId = gameIds[i];
            for (uint256 j = 0; j < i; ++j) {
                if (gameIds[j] == gameId) revert DuplicateGame(gameId);
            }
            // slither-disable-next-line unused-return (winner and recordedAt are not needed here)
            (IResultsRegistry.GameStatus status, , uint64 startTime, ) = registry.outcomeOf(gameId);
            if (status != IResultsRegistry.GameStatus.Scheduled) revert GameNotSchedulable(gameId);
            if (startTime < lockTime) revert LockAfterStart(gameId);
        }

        bytes32 gamesHash = keccak256(abi.encodePacked(gameIds));
        _rounds[roundId] = Round({
            leagueId: leagueId,
            gamesHash: gamesHash,
            opensAt: opensAt,
            lockTime: lockTime,
            matchday: matchday,
            gameCount: uint8(gameIds.length),
            state: RoundState.Scheduled,
            submissions: 0,
            outcomes: 0
        });
        _roundGames[roundId] = gameIds;
        _leagueRounds[leagueId].push(roundId);
        ++l.roundCount;

        emit RoundScheduled(roundId, leagueId, matchday, opensAt, lockTime, gamesHash, gameIds);
    }

    /// @notice Move the lock of a round that has not locked yet (e.g. a game was moved earlier).
    ///         The new lock is at least MIN_LOCK_NOTICE ahead, so the submitter has time to land
    ///         the picks already confirmed for the round. A game moved to start sooner than that
    ///         cannot keep its round's lock before it, so it does not count in that round.
    ///         As MIN_LOCK_NOTICE > MAX_CLOCK_SKEW, the lock also stays after every stored
    ///         `confirmedAt` (at most the block time + MAX_CLOCK_SKEW when it was accepted).
    function updateRoundLock(bytes32 roundId, uint64 newLockTime) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Scheduled) revert RoundNotActive(roundId);
        if (block.timestamp >= r.lockTime) revert RoundLocked(roundId);
        if (newLockTime < block.timestamp + MIN_LOCK_NOTICE || newLockTime <= r.opensAt) revert InvalidSchedule();

        bytes32[] storage gameIds = _roundGames[roundId];
        for (uint256 i = 0; i < gameIds.length; ++i) {
            // slither-disable-next-line unused-return (only the start time is needed here)
            (, , uint64 startTime, ) = registry.outcomeOf(gameIds[i]);
            if (startTime < newLockTime) revert LockAfterStart(gameIds[i]);
        }

        uint64 old = r.lockTime;
        r.lockTime = newLockTime;
        emit RoundLockUpdated(roundId, old, newLockTime);
    }

    // ---------------------------------------------------------------------
    // Submitter (relayer): predictions
    // ---------------------------------------------------------------------

    /// @notice Store one user's signed prediction. Reverts with the reason if it is not accepted.
    function submitFor(
        address user,
        bytes32 roundId,
        bytes32 picksHash,
        bytes calldata picks,
        uint64 confirmedAt,
        bytes calldata signature
    ) external onlyRole(SUBMITTER_ROLE) whenNotPaused {
        Round storage r = _openRound(roundId);
        SubmitStatus status = _submit(r, roundId, user, picksHash, picks, confirmedAt, signature);
        if (status != SubmitStatus.Ok) revert SubmissionRejected(user, status);
    }

    /// @notice Store many signed predictions for one round. Round-level problems revert the batch;
    ///         item-level problems skip the item (event + status), so retries are idempotent.
    function submitForBatch(
        bytes32 roundId,
        BatchItem[] calldata items
    ) external onlyRole(SUBMITTER_ROLE) whenNotPaused returns (SubmitStatus[] memory statuses) {
        if (items.length == 0) revert EmptyBatch();
        if (items.length > MAX_BATCH) revert BatchTooLarge(items.length, MAX_BATCH);
        Round storage r = _openRound(roundId);

        statuses = new SubmitStatus[](items.length);
        for (uint256 i = 0; i < items.length; ++i) {
            BatchItem calldata it = items[i];
            SubmitStatus status = _submit(r, roundId, it.user, it.picksHash, it.picks, it.confirmedAt, it.signature);
            statuses[i] = status;
            if (status != SubmitStatus.Ok) emit SubmissionSkipped(roundId, it.user, status);
        }
    }

    // ---------------------------------------------------------------------
    // Settlement
    // ---------------------------------------------------------------------

    /// @notice Snapshot the outcomes of a locked round once all its games have a result in the
    ///         ResultsRegistry, none of them can be corrected any more and `finalizationDelay` has
    ///         passed since the last of them was recorded. Permissionless: it is deterministic.
    function finalizeRound(bytes32 roundId) external whenNotPaused {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Scheduled) revert RoundNotActive(roundId);
        if (block.timestamp < r.lockTime) revert RoundNotLocked(roundId);

        (uint64 outcomes, uint64 readyAt, bytes32 pending) = _outcomes(roundId, r.lockTime);
        if (pending != bytes32(0)) revert NoResult(pending);
        if (block.timestamp < readyAt) revert FinalizationPending(roundId, readyAt);

        r.outcomes = outcomes;
        r.state = RoundState.Finalized;
        emit RoundFinalized(roundId, outcomes, PicksLib.countedGames(outcomes, r.gameCount));
    }

    // ---------------------------------------------------------------------
    // Steward
    // ---------------------------------------------------------------------

    /// @notice Works while paused: pausing, cancelling the round, then unpausing is the remedy for
    ///         a round built on a wrong result.
    function cancelRound(bytes32 roundId, string calldata reason) external onlyRole(STEWARD_ROLE) {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Scheduled) revert RoundNotActive(roundId);
        r.state = RoundState.Cancelled;
        emit RoundCancelled(roundId, reason);
    }

    /// @notice Propose the final standings once every round is finalized or cancelled. They are
    ///         public for STANDINGS_REVIEW_PERIOD before finalizeLeague can anchor them; a new
    ///         proposal replaces the previous one and restarts the period. From the first proposal
    ///         on, the league takes no new round: the season is over (only the admin can reopen it,
    ///         see withdrawStandings).
    /// @param standingsRoot OZ StandardMerkleTree root of StandingLeaf rows
    ///        (bytes32 leagueId, address account, uint32 rank, uint32 points, uint32 correct,
    ///         uint32 counted, uint16 roundsPlayed, uint64 sumLeadTime)
    /// @param reportHash hash of the published report (tree dump + standings) at `reportURI`
    function proposeStandings(
        bytes32 leagueId,
        bytes32 standingsRoot,
        uint32 totalPlayers,
        bytes32 reportHash,
        string calldata reportURI
    ) external onlyRole(STEWARD_ROLE) whenNotPaused {
        League storage l = _leagues[leagueId];
        if (!l.exists || l.finalized) revert LeagueNotActive(leagueId);
        if (standingsRoot == bytes32(0) || totalPlayers == 0) revert InvalidStandings();

        bytes32[] storage roundIds = _leagueRounds[leagueId];
        bool anyFinalized = false;
        for (uint256 i = 0; i < roundIds.length; ++i) {
            RoundState state = _rounds[roundIds[i]].state;
            if (state == RoundState.Scheduled) revert RoundsPending(leagueId);
            if (state == RoundState.Finalized) anyFinalized = true;
        }
        if (!anyFinalized) revert RoundsPending(leagueId);

        _proposals[leagueId] = StandingsProposal({
            standingsRoot: standingsRoot,
            reportHash: reportHash,
            totalPlayers: totalPlayers,
            proposedAt: uint64(block.timestamp),
            roundCount: l.roundCount
        });
        uint64 finalizableAt_ = uint64(block.timestamp) + STANDINGS_REVIEW_PERIOD;
        emit StandingsProposed(leagueId, standingsRoot, totalPlayers, reportHash, reportURI, finalizableAt_);
    }

    /// @notice Anchor the proposed standings after the review period. Write-once.
    function finalizeLeague(bytes32 leagueId) external onlyRole(STEWARD_ROLE) whenNotPaused {
        League storage l = _leagues[leagueId];
        if (!l.exists || l.finalized) revert LeagueNotActive(leagueId);
        StandingsProposal storage p = _proposals[leagueId];
        if (p.proposedAt == 0) revert NoStandingsProposal(leagueId);
        uint64 finalizableAt_ = p.proposedAt + STANDINGS_REVIEW_PERIOD;
        if (block.timestamp < finalizableAt_) revert ReviewPeriodOpen(leagueId, finalizableAt_);
        // Every round was settled at proposal time and settled rounds never change. scheduleRound
        // refuses new rounds once standings are proposed, so this only guards that invariant.
        if (l.roundCount != p.roundCount) revert StandingsOutdated(leagueId);

        l.finalized = true;
        l.finalizedAt = uint64(block.timestamp);
        l.standingsRoot = p.standingsRoot;
        l.totalPlayers = p.totalPlayers;
        l.reportHash = p.reportHash;
        emit LeagueFinalized(leagueId, p.standingsRoot, p.totalPlayers, p.reportHash);
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    /// @notice Withdraw standings proposed too early (e.g. mid-season): the league takes rounds again
    ///         and the steward proposes once it is over. Admin only, so the operator key still cannot
    ///         hold up finalizeLeague. Works while paused, like every admin function.
    function withdrawStandings(bytes32 leagueId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        League storage l = _leagues[leagueId];
        if (!l.exists || l.finalized) revert LeagueNotActive(leagueId);
        if (_proposals[leagueId].proposedAt == 0) revert NoStandingsProposal(leagueId);
        delete _proposals[leagueId];
        emit StandingsWithdrawn(leagueId);
    }

    function setFinalizationDelay(uint64 delay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setFinalizationDelay(delay);
    }

    /// @notice The steward's hot wallet can stop the contract in minutes; only the admin resumes it.
    function pause() external onlyRole(STEWARD_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function roundIdOf(bytes32 leagueId, uint16 matchday) public pure returns (bytes32) {
        return keccak256(abi.encode(leagueId, matchday));
    }

    function getLeague(bytes32 leagueId) external view returns (League memory) {
        return _leagues[leagueId];
    }

    function getStandingsProposal(bytes32 leagueId) external view returns (StandingsProposal memory) {
        return _proposals[leagueId];
    }

    /// @notice Check one row of the standings. `inTree`: the proof matches the anchored root or,
    ///         before finalizeLeague, the proposed one. `matchesChain`: its stats equal
    ///         leagueStatsOf. The rank is not checked: it depends on every other row.
    function checkStanding(
        bytes32 leagueId,
        StandingLeaf calldata leaf,
        bytes32[] calldata proof
    ) external view returns (bool inTree, bool matchesChain) {
        League storage l = _leagues[leagueId];
        bytes32 root = l.finalized ? l.standingsRoot : _proposals[leagueId].standingsRoot;
        bytes32 leafHash = keccak256(bytes.concat(keccak256(abi.encode(leaf)))); // StandardMerkleTree
        inTree = root != bytes32(0) && leaf.leagueId == leagueId && MerkleProof.verifyCalldata(proof, root, leafHash);

        LeagueStats memory s = leagueStatsOf(leagueId, leaf.account);
        matchesChain =
            s.points == leaf.points &&
            s.correct == leaf.correct &&
            s.counted == leaf.counted &&
            s.roundsPlayed == leaf.roundsPlayed &&
            s.sumLeadTime == leaf.sumLeadTime;
    }

    function leagueRoundIds(bytes32 leagueId) external view returns (bytes32[] memory) {
        return _leagueRounds[leagueId];
    }

    function getRound(bytes32 roundId) external view returns (Round memory) {
        return _rounds[roundId];
    }

    function getRoundGames(bytes32 roundId) external view returns (bytes32[] memory) {
        return _roundGames[roundId];
    }

    /// @notice Earliest time `finalizeRound` can succeed, or 0 while the round is not scheduled or
    ///         one of its games has no result yet. A correction of one of its results moves it.
    function finalizableAt(bytes32 roundId) external view returns (uint64) {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Scheduled) return 0;
        (, uint64 readyAt, bytes32 pending) = _outcomes(roundId, r.lockTime);
        if (pending != bytes32(0)) return 0;
        return readyAt > r.lockTime ? readyAt : r.lockTime;
    }

    function isRoundOpen(bytes32 roundId) public view returns (bool) {
        Round storage r = _rounds[roundId];
        return r.state == RoundState.Scheduled && block.timestamp >= r.opensAt && block.timestamp < r.lockTime;
    }

    function getEntry(
        bytes32 roundId,
        address user
    ) external view returns (uint64 confirmedAt, uint64 submittedAt, bytes memory picks) {
        Entry storage e = _entries[roundId][user];
        if (e.submittedAt == 0) return (0, 0, "");
        return (e.confirmedAt, e.submittedAt, PicksLib.unpack(e.packedPicks, _rounds[roundId].gameCount));
    }

    function hasSubmitted(bytes32 roundId, address user) external view returns (bool) {
        return _entries[roundId][user].submittedAt != 0;
    }

    /// @notice The "receipt" shown in the app: keccak256(abi.encode(roundId, gamesHash, keccak256(picks))).
    function computePicksHash(bytes32 roundId, bytes calldata picks) external view returns (bytes32) {
        return _picksHash(roundId, _rounds[roundId].gamesHash, picks);
    }

    /// @notice EIP-712 digest the user's key signs.
    function submissionDigest(
        address user,
        bytes32 roundId,
        bytes32 picksHash,
        uint64 confirmedAt
    ) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(SUBMISSION_TYPEHASH, user, roundId, picksHash, confirmedAt)));
    }

    /// @notice Layer-0 score of `user` in a finalized round; (0, 0) if not finalized or no entry.
    function scoreOf(bytes32 roundId, address user) public view returns (uint8 correct, uint8 counted) {
        Round storage r = _rounds[roundId];
        Entry storage e = _entries[roundId][user];
        if (r.state != RoundState.Finalized || e.submittedAt == 0) return (0, 0);
        return PicksLib.score(e.packedPicks, r.outcomes, r.gameCount);
    }

    /// @notice Aggregated layer-0 stats of `user` over the league's finalized rounds.
    ///         A round counts as played only if the user submitted and at least one game counted.
    function leagueStatsOf(bytes32 leagueId, address user) public view returns (LeagueStats memory s) {
        bytes32[] storage roundIds = _leagueRounds[leagueId];
        for (uint256 i = 0; i < roundIds.length; ++i) {
            Round storage r = _rounds[roundIds[i]];
            if (r.state != RoundState.Finalized) continue;
            Entry storage e = _entries[roundIds[i]][user];
            if (e.submittedAt == 0) continue;
            (uint8 correct, uint8 counted) = PicksLib.score(e.packedPicks, r.outcomes, r.gameCount);
            if (counted == 0) continue;
            s.correct += correct;
            s.counted += counted;
            s.roundsPlayed += 1;
            s.sumLeadTime += r.lockTime - e.confirmedAt;
        }
        s.points = s.correct;
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev Outcomes of a round's games (2 bits each) and the time the round can settle: the
    ///      latest of each game's `recordedAt + finalizationDelay` and `correctableUntil`, so a
    ///      result that can still change never settles, whatever the two windows are set to.
    ///      `pending` is the first game without a result, or 0 when all have one. A game counts
    ///      only if it was played or forfeited and did not start before the lock.
    function _outcomes(
        bytes32 roundId,
        uint64 lockTime
    ) private view returns (uint64 outcomes, uint64 readyAt, bytes32 pending) {
        bytes32[] storage gameIds = _roundGames[roundId];
        uint64 delay = finalizationDelay;
        for (uint256 i = 0; i < gameIds.length; ++i) {
            (IResultsRegistry.GameStatus status, IResultsRegistry.Side winner, uint64 startTime, uint64 recordedAt) = registry
                .outcomeOf(gameIds[i]);
            if (recordedAt == 0) return (0, 0, gameIds[i]);
            uint64 gameReadyAt = recordedAt + delay;
            uint64 correctable = registry.correctableUntil(gameIds[i]);
            if (correctable > gameReadyAt) gameReadyAt = correctable;
            if (gameReadyAt > readyAt) readyAt = gameReadyAt;
            bool counts = (status == IResultsRegistry.GameStatus.Final ||
                status == IResultsRegistry.GameStatus.Forfeit) && startTime >= lockTime;
            if (counts) outcomes |= uint64(uint8(winner)) << uint8(2 * i); // i < MAX_GAMES
        }
    }

    function _setFinalizationDelay(uint64 delay) private {
        if (delay < MIN_FINALIZATION_DELAY || delay > MAX_FINALIZATION_DELAY) revert DelayOutOfRange(delay);
        finalizationDelay = delay;
        emit FinalizationDelaySet(delay);
    }

    function _openRound(bytes32 roundId) private view returns (Round storage r) {
        if (!isRoundOpen(roundId)) revert RoundNotOpen(roundId);
        return _rounds[roundId];
    }

    function _submit(
        Round storage r,
        bytes32 roundId,
        address user,
        bytes32 picksHash,
        bytes calldata picks,
        uint64 confirmedAt,
        bytes calldata signature
    ) private returns (SubmitStatus) {
        if (user == address(0)) return SubmitStatus.InvalidUser;
        Entry storage e = _entries[roundId][user];
        if (e.submittedAt != 0) return SubmitStatus.Duplicate;

        if (picks.length != r.gameCount) return SubmitStatus.InvalidPicks;
        (bool ok, uint64 packed) = PicksLib.pack(picks);
        if (!ok) return SubmitStatus.InvalidPicks;
        if (_picksHash(roundId, r.gamesHash, picks) != picksHash) return SubmitStatus.PicksHashMismatch;

        if (
            confirmedAt < r.opensAt ||
            confirmedAt >= r.lockTime ||
            confirmedAt > block.timestamp + MAX_CLOCK_SKEW
        ) return SubmitStatus.InvalidConfirmedAt;

        if (!_validSignature(user, roundId, picksHash, confirmedAt, signature)) {
            return SubmitStatus.InvalidSignature;
        }

        e.confirmedAt = confirmedAt;
        e.submittedAt = uint64(block.timestamp);
        e.packedPicks = packed;
        ++r.submissions;
        emit PredictionSubmitted(roundId, user, picksHash, picks, confirmedAt);
        return SubmitStatus.Ok;
    }

    function _validSignature(
        address user,
        bytes32 roundId,
        bytes32 picksHash,
        uint64 confirmedAt,
        bytes calldata signature
    ) private view returns (bool) {
        bytes32 digest = submissionDigest(user, roundId, picksHash, confirmedAt);
        // tryRecover rejects malleable (high-s) and malformed signatures.
        // slither-disable-next-line unused-return (the error argument adds nothing to `err`)
        (address recovered, ECDSA.RecoverError err, ) = ECDSA.tryRecoverCalldata(digest, signature);
        return err == ECDSA.RecoverError.NoError && recovered == user;
    }

    function _picksHash(bytes32 roundId, bytes32 gamesHash, bytes calldata picks) private pure returns (bytes32) {
        return keccak256(abi.encode(roundId, gamesHash, keccak256(picks)));
    }
}
