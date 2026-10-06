// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Test} from "forge-std/Test.sol";

import {IPredictions} from "../contracts/interfaces/IPredictions.sol";

/// @dev Recomputes every value in test/vectors/m2-vectors.json (generated with viem by
///      scripts/gen-vectors.ts) using the exact Solidity encodings the contracts use.
contract VectorsTest is Test {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant SUBMISSION_TYPEHASH =
        keccak256("Submission(address user,bytes32 roundId,bytes32 picksHash,uint64 confirmedAt)");

    string internal json;

    function setUp() public {
        json = vm.readFile(string.concat(vm.projectRoot(), "/test/vectors/m2-vectors.json"));
    }

    function test_Identifiers() public view {
        bytes32 leagueId = keccak256(bytes(vm.parseJsonString(json, ".league.slug")));
        assertEq(leagueId, vm.parseJsonBytes32(json, ".league.leagueId"));

        string[] memory canonical = vm.parseJsonStringArray(json, ".round.canonicalGameIds");
        bytes32[] memory gameIds = vm.parseJsonBytes32Array(json, ".round.gameIds");
        for (uint256 i = 0; i < canonical.length; ++i) {
            assertEq(keccak256(bytes(canonical[i])), gameIds[i]);
        }

        uint16 matchday = uint16(vm.parseJsonUint(json, ".round.matchday"));
        assertEq(keccak256(abi.encode(leagueId, matchday)), vm.parseJsonBytes32(json, ".round.roundId"));
        assertEq(keccak256(abi.encodePacked(gameIds)), vm.parseJsonBytes32(json, ".round.gamesHash"));
    }

    function test_TeamCodes() public view {
        for (uint256 i = 0; i < 3; ++i) {
            string memory base = string.concat(".teams[", vm.toString(i), "]");
            assertEq(
                bytes32(bytes(vm.parseJsonString(json, string.concat(base, ".home")))),
                vm.parseJsonBytes32(json, string.concat(base, ".homeCode"))
            );
            assertEq(
                bytes32(bytes(vm.parseJsonString(json, string.concat(base, ".away")))),
                vm.parseJsonBytes32(json, string.concat(base, ".awayCode"))
            );
        }
    }

    function test_SubmissionsHashAndSignature() public view {
        bytes32 roundId = vm.parseJsonBytes32(json, ".round.roundId");
        bytes32 gamesHash = vm.parseJsonBytes32(json, ".round.gamesHash");
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(vm.parseJsonString(json, ".domain.name"))),
                keccak256(bytes(vm.parseJsonString(json, ".domain.version"))),
                vm.parseJsonUint(json, ".domain.chainId"),
                vm.parseJsonAddress(json, ".domain.verifyingContract")
            )
        );

        for (uint256 i = 0; i < 2; ++i) {
            string memory base = string.concat(".submissions[", vm.toString(i), "]");
            address user = vm.parseJsonAddress(json, string.concat(base, ".user"));
            bytes memory picks = vm.parseJsonBytes(json, string.concat(base, ".picks"));
            uint64 confirmedAt = uint64(vm.parseUint(vm.parseJsonString(json, string.concat(base, ".confirmedAt"))));

            bytes32 picksHash = keccak256(abi.encode(roundId, gamesHash, keccak256(picks)));
            assertEq(picksHash, vm.parseJsonBytes32(json, string.concat(base, ".picksHash")));

            bytes32 structHash = keccak256(abi.encode(SUBMISSION_TYPEHASH, user, roundId, picksHash, confirmedAt));
            bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
            assertEq(digest, vm.parseJsonBytes32(json, string.concat(base, ".digest")));

            bytes memory sig = vm.parseJsonBytes(json, string.concat(base, ".signature"));
            assertEq(_recover(digest, sig), user);
        }
    }

    function test_ResultSourceHash() public view {
        bytes memory csv = bytes(vm.parseJsonString(json, ".result.csv"));
        assertEq(sha256(csv), vm.parseJsonBytes32(json, ".result.sourceHash"));
    }

    function test_StandingsProofs() public view {
        bytes32 leagueId = vm.parseJsonBytes32(json, ".league.leagueId");
        bytes32 root = vm.parseJsonBytes32(json, ".standings.root");
        for (uint256 i = 0; i < 2; ++i) {
            string memory base = string.concat(".standings.leaves[", vm.toString(i), "]");
            IPredictions.StandingLeaf memory row = IPredictions.StandingLeaf({
                leagueId: leagueId,
                account: vm.parseJsonAddress(json, string.concat(base, ".account")),
                rank: uint32(vm.parseJsonUint(json, string.concat(base, ".rank"))),
                points: uint32(vm.parseJsonUint(json, string.concat(base, ".points"))),
                correct: uint32(vm.parseJsonUint(json, string.concat(base, ".correct"))),
                counted: uint32(vm.parseJsonUint(json, string.concat(base, ".counted"))),
                roundsPlayed: uint16(vm.parseJsonUint(json, string.concat(base, ".roundsPlayed"))),
                sumLeadTime: uint64(vm.parseUint(vm.parseJsonString(json, string.concat(base, ".sumLeadTime"))))
            });
            // Same leaf hash as Predictions.checkStanding.
            bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(row))));
            bytes32[] memory proof = vm.parseJsonBytes32Array(json, string.concat(base, ".proof"));
            assertTrue(MerkleProof.verify(proof, root, leaf));
        }
    }

    function _recover(bytes32 digest, bytes memory sig) internal pure returns (address) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
        return ecrecover(digest, v, r, s);
    }
}
