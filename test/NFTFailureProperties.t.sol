// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FrogHarness} from "./NFT.t.sol";
import {HFROG} from "src/HFROG.sol";
import {HashFrog} from "src/HashFrog.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract SelectiveNFTReceiver is IERC721Receiver {
    bool public accept;

    function setAccept(bool enabled) external {
        accept = enabled;
    }

    function mine(HashFrog frog, bytes32 seed) external payable {
        frog.mine{value: msg.value}(0, seed, 99);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        return accept ? IERC721Receiver.onERC721Received.selector : bytes4(0);
    }
}

contract PaymentReentryProbe {
    HashFrog immutable frog;
    uint256 public blocked;

    constructor(HashFrog f) {
        frog = f;
    }

    receive() external payable {
        (bool ok, bytes memory reason) = address(frog).call(abi.encodeCall(HashFrog.flush, ()));
        require(!ok && bytes4(reason) == bytes4(keccak256("ReentrancyGuardReentrantCall()")), "flush reentry");
        (ok, reason) = address(frog).call(abi.encodeCall(HashFrog.burn, (1)));
        require(!ok && bytes4(reason) == bytes4(keccak256("ReentrancyGuardReentrantCall()")), "burn reentry");
        blocked += 2;
    }
}

contract NFTFailurePropertiesTest is Test {
    FrogHarness frog;
    address constant MINER = address(0xA11CE);
    bytes32 refHash = keccak256("reference");
    uint256 constant PRICE = 0.0019 ether;

    function setUp() public {
        vm.warp(1_000_000);
        vm.roll(100);
        vm.setBlockhash(99, refHash);
        frog = new FrogHarness(new PoolManager(address(this)), new HFROG(), new MockERC20("IMD", "IMD", 1e30));
        frog.setTarget(type(uint256).max);
        vm.deal(MINER, 10 ether);
    }

    function test_RejectingNFTReceiverRollsBackProofSeedLatchAndPayments() public {
        SelectiveNFTReceiver receiver = new SelectiveNFTReceiver();
        bytes32 seed = frog.lastSeed();
        uint256 hackBefore = frog.HACKATHON().balance;
        uint256 teamBefore = frog.TEAM().balance;
        vm.expectRevert(abi.encodeWithSignature("ERC721InvalidReceiver(address)", address(receiver)));
        receiver.mine{value: PRICE}(frog, seed);
        assertEq(frog.totalMinted(), 0);
        assertEq(frog.lastSeed(), seed);
        assertEq(frog.seedOf(1), bytes32(0));
        assertEq(frog.mintTimes(0), 0);
        assertEq(frog.HACKATHON().balance, hackBefore);
        assertEq(frog.TEAM().balance, teamBefore);
        assertEq(address(frog).balance, 0);
        receiver.setAccept(true);
        // No reset of difficulty, transaction latch or seed-used state between attempts.
        receiver.mine{value: PRICE}(frog, seed);
        assertEq(frog.ownerOf(1), address(receiver));
        assertEq(frog.seedOf(1), keccak256(abi.encodePacked(address(receiver), uint256(0), seed, refHash)));
    }

    function test_ETHRecipientCannotReenterMintPaymentsOrBurn() public {
        PaymentReentryProbe probe = new PaymentReentryProbe(frog);
        vm.etch(frog.HACKATHON(), address(probe).code);
        bytes32 seed = frog.lastSeed();
        vm.prank(MINER);
        frog.mine{value: PRICE}(0, seed, 99);
        assertEq(PaymentReentryProbe(payable(frog.HACKATHON())).blocked(), 2);
        assertEq(frog.ethCredit(frog.HACKATHON()), 0, "probe must run within payment gas budget");
        assertEq(frog.ethToHackathon(), PRICE * 85 / 100);
        assertEq(frog.ownerOf(1), MINER);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_WrongPriceNeverConsumesProofOrPaysRecipients(uint64 raw) public {
        uint256 price = bound(uint256(raw), 0, 2 * PRICE);
        if (price == PRICE) price++;
        bytes32 seed = frog.lastSeed();
        uint256 minerBefore = MINER.balance;
        uint256 hackBefore = frog.HACKATHON().balance;
        uint256 teamBefore = frog.TEAM().balance;
        vm.prank(MINER);
        vm.expectRevert(HashFrog.WrongPrice.selector);
        frog.mine{value: price}(0, seed, 99);
        assertEq(MINER.balance, minerBefore);
        assertEq(frog.HACKATHON().balance, hackBefore);
        assertEq(frog.TEAM().balance, teamBefore);
        assertEq(frog.totalMinted(), 0);
        assertEq(frog.lastSeed(), seed);
        vm.prank(MINER);
        frog.mine{value: PRICE}(0, seed, 99);
        assertEq(frog.ownerOf(1), MINER);
    }

    function test_ProofCannotBeReusedWithDifferentReferenceHash() public {
        bytes32 seed = frog.lastSeed();
        bytes32 otherHash = keccak256("another reference block");
        vm.setBlockhash(98, otherHash);
        uint256 nonce;
        uint256 solved;
        for (;; ++nonce) {
            solved = uint256(keccak256(abi.encodePacked(MINER, nonce, seed, refHash)));
            uint256 other = uint256(keccak256(abi.encodePacked(MINER, nonce, seed, otherHash)));
            if (solved < type(uint256).max && other > solved + 1) break;
        }
        frog.setTarget(solved + 1);
        vm.prank(MINER);
        vm.expectRevert(HashFrog.InvalidProof.selector);
        frog.mine{value: PRICE}(nonce, seed, 98);
        vm.prank(MINER);
        frog.mine{value: PRICE}(nonce, seed, 99);
        assertEq(frog.seedOf(1), bytes32(solved));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_RetargetUsesEightMintElapsedTimeWithBothClamps(uint16 raw) public {
        uint256 elapsed = bound(uint256(raw), 0, 2000);
        uint256 oldTarget = type(uint256).max >> 10;
        for (uint256 j; j < 7; ++j) {
            frog.nextTransaction();
            bytes32 seed = frog.lastSeed();
            vm.prank(MINER);
            frog.mine{value: PRICE}(0, seed, 99);
        }
        assertEq(frog.target(), type(uint256).max, "retarget must wait for mint eight");
        frog.setTarget(oldTarget);
        frog.nextTransaction();
        vm.warp(1_000_000 + elapsed);
        bytes32 last = frog.lastSeed();
        uint256 nonce;
        while (uint256(keccak256(abi.encodePacked(MINER, nonce, last, refHash))) >= oldTarget) ++nonce;
        vm.prank(MINER);
        frog.mine{value: PRICE}(nonce, last, 99);
        uint256 adjusted = frog.target();
        assertEq(frog.epochStarted(), 1_000_000 + elapsed);
        if (elapsed < 120) {
            assertEq(adjusted, oldTarget / 4);
        } else if (elapsed > 960) {
            assertEq(adjusted, oldTarget * 2);
        } else {
            // Check the ratio and rounding bounds without reproducing mulDiv.
            assertLe(adjusted * 480, oldTarget * elapsed);
            assertLt(oldTarget * elapsed - adjusted * 480, 480);
        }
    }
}
