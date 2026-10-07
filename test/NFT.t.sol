// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {HashFrog} from "../src/HashFrog.sol";
import {HFROG} from "../src/HFROG.sol";
import {FrogRouter} from "../src/FrogRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Only the test harness can reset the transaction latch / set difficulty.
/// Foundry executes all calls in one test in a single EVM transaction.
contract FrogHarness is HashFrog {
    constructor(IPoolManager m, IERC20 t, IERC20 i) HashFrog(m, t, i, FrogRouter(address(0)), address(0)) {}

    function nextTransaction() external {
        bytes32 slot = MINT_TX_SLOT;
        assembly ("memory-safe") { tstore(slot, 0) }
    }

    function setTarget(uint256 t) external {
        target = t;
    }
}

contract RejectETH {
    receive() external payable {
        revert("no");
    }
}

contract GasBombETH {
    uint256[10] data;

    receive() external payable {
        for (uint256 i; i < 10; ++i) {
            data[i] = msg.value + i;
        }
    }
}

contract HungryETH {
    uint256 public count;
    uint256 public received;

    receive() external payable {
        count++;
        received += msg.value;
    }
}

contract ReenterMint is IERC721Receiver {
    HashFrog immutable frog;
    bool public blocked;

    constructor(HashFrog f) {
        frog = f;
    }

    function go(bytes32 seed, uint256 refBlock) external payable {
        frog.mine{value: msg.value}(0, seed, refBlock);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        (bool ok,) = address(frog).call(abi.encodeCall(HashFrog.flush, ()));
        blocked = !ok;
        return this.onERC721Received.selector;
    }
}

contract DoubleMint is IERC721Receiver {
    function go(HashFrog f) external payable {
        f.mine{value: 0.0019 ether}(0, f.lastSeed(), 99);
        f.mine{value: 0.0019 ether}(0, f.lastSeed(), 99);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract NFTTest is Test {
    FrogHarness frog;
    HFROG token;
    MockERC20 imd;
    PoolManager manager;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    bytes32 refHash = keccak256("reference");
    uint256 constant PRICE = 0.0019 ether;

    function setUp() public {
        vm.warp(1_000_000);
        vm.roll(100);
        vm.setBlockhash(99, refHash);
        manager = new PoolManager(address(this));
        token = new HFROG();
        imd = new MockERC20("IMD", "IMD", 1e27);
        frog = new FrogHarness(manager, token, imd);
        frog.setTarget(type(uint256).max);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function mintOne(address to) internal returns (uint256) {
        frog.nextTransaction();
        bytes32 seed = frog.lastSeed();
        vm.prank(to);
        return frog.mine{value: PRICE}(0, seed, 99);
    }

    function testEverMintedCapAndNeverReuseBurnedId() public {
        for (uint256 i; i < 2000; ++i) {
            vm.warp(vm.getBlockTimestamp() + 60);
            assertEq(mintOne(alice), i + 1);
        }
        assertEq(frog.totalMinted(), 2000);
        vm.prank(alice);
        frog.burn(1);
        assertEq(frog.totalBurned(), 1);
        frog.nextTransaction();
        bytes32 seed = frog.lastSeed();
        vm.prank(alice);
        vm.expectRevert(HashFrog.SoldOut.selector);
        frog.mine{value: PRICE}(0, seed, 99);
        assertEq(frog.totalMinted(), 2000);
    }

    function testRollingWindowNotCalendarHour() public {
        for (uint256 i; i < 60; ++i) {
            frog.setTarget(type(uint256).max);
            if (i == 30) vm.warp(vm.getBlockTimestamp() + 1800);
            mintOne(alice);
        }
        (uint256 slots, uint256 next) = frog.freeSlots();
        assertEq(slots, 0);
        assertEq(next, 1_003_600);
        bytes32 seed = frog.lastSeed();
        frog.nextTransaction();
        vm.warp(1_003_599);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(HashFrog.HourFull.selector, 1_003_600));
        frog.mine{value: PRICE}(0, seed, 99);
        vm.warp(1_003_600);
        (slots,) = frog.freeSlots();
        assertEq(slots, 30);
        frog.setTarget(type(uint256).max);
        mintOne(bob);
        (slots,) = frog.freeSlots();
        assertEq(slots, 29);
    }

    function testWrongPriceReferenceSeedProofAndSenderBinding() public {
        bytes32 seed = frog.lastSeed();
        vm.prank(alice);
        vm.expectRevert(HashFrog.WrongPrice.selector);
        frog.mine{value: PRICE + 1}(0, seed, 99);
        vm.prank(alice);
        vm.expectRevert(HashFrog.WrongPrice.selector);
        frog.mine{value: PRICE - 1}(0, seed, 99);
        vm.prank(alice);
        vm.expectRevert(HashFrog.InvalidReferenceBlock.selector);
        frog.mine{value: PRICE}(0, seed, 100);
        vm.setBlockhash(35, refHash);
        vm.prank(alice);
        vm.expectRevert(HashFrog.InvalidReferenceBlock.selector);
        frog.mine{value: PRICE}(0, seed, 35);
        uint256 nonce;
        uint256 aliceHash;
        for (;; nonce++) {
            aliceHash = uint256(keccak256(abi.encodePacked(alice, nonce, seed, refHash)));
            if (uint256(keccak256(abi.encodePacked(bob, nonce, seed, refHash))) > aliceHash + 1) break;
        }
        frog.setTarget(aliceHash);
        vm.prank(alice);
        vm.expectRevert(HashFrog.InvalidProof.selector);
        frog.mine{value: PRICE}(nonce, seed, 99);
        frog.setTarget(aliceHash + 1);
        vm.prank(bob);
        vm.expectRevert(HashFrog.InvalidProof.selector);
        frog.mine{value: PRICE}(nonce, seed, 99);
        vm.prank(alice);
        frog.mine{value: PRICE}(nonce, seed, 99);
        assertEq(frog.seedOf(1), bytes32(aliceHash));
        frog.nextTransaction();
        vm.prank(alice);
        vm.expectRevert(HashFrog.StaleSeed.selector);
        frog.mine{value: PRICE}(nonce, seed, 99);
    }

    function testOnePerTransactionAcrossCallersAndReferenceBoundary() public {
        vm.setBlockhash(36, refHash);
        bytes32 seed = frog.lastSeed();
        vm.prank(alice);
        frog.mine{value: PRICE}(0, seed, 36);
        frog.nextTransaction();
        DoubleMint batch = new DoubleMint();
        vm.expectRevert(HashFrog.OneMintPerTransaction.selector);
        batch.go{value: 2 * PRICE}(frog);
    }

    function testExactEthSplitCreditAndFlush() public {
        address hack = frog.HACKATHON();
        address team = frog.TEAM();
        vm.deal(hack, 0);
        vm.deal(team, 0);
        HungryETH hungry = new HungryETH();
        vm.etch(hack, address(hungry).code);
        mintOne(alice);
        assertEq(hack.balance, PRICE * 85 / 100);
        assertEq(team.balance, PRICE * 15 / 100);
        assertEq(HungryETH(payable(hack)).count(), 1);
        assertEq(HungryETH(payable(hack)).received(), PRICE * 85 / 100);
        RejectETH reject = new RejectETH();
        vm.etch(hack, address(reject).code);
        vm.etch(team, address(reject).code);
        mintOne(alice);
        assertEq(frog.ethCredit(hack), PRICE * 85 / 100);
        assertEq(frog.ethCredit(team), PRICE * 15 / 100);
        assertEq(address(frog).balance, PRICE);
        vm.prank(bob);
        frog.flush();
        assertEq(address(frog).balance, PRICE);
        vm.etch(hack, "");
        vm.etch(team, "");
        vm.prank(bob);
        frog.flush();
        assertEq(address(frog).balance, 0);
        assertEq(frog.ethCredit(hack), 0);
        assertEq(frog.ethCredit(team), 0);
        assertEq(hack.balance, 2 * PRICE * 85 / 100);
        assertEq(team.balance, 2 * PRICE * 15 / 100);
        assertEq(frog.ethToHackathon(), 2 * PRICE * 85 / 100);
        assertEq(frog.ethToTeam(), 2 * PRICE * 15 / 100);
    }

    function testGasExhaustionCreatesRetryableCredit() public {
        address hack = frog.HACKATHON();
        GasBombETH bomb = new GasBombETH();
        vm.etch(hack, address(bomb).code);
        mintOne(alice);
        assertEq(frog.ethCredit(hack), PRICE * 85 / 100);
        assertEq(address(frog).balance, PRICE * 85 / 100);
        vm.etch(hack, "");
        frog.flush();
        assertEq(frog.ethCredit(hack), 0);
        assertEq(address(frog).balance, 0);
    }

    function testFuzzBurnConservation(uint96 rawTokens, uint96 rawIMD, uint8 rawCount) public {
        uint256 count = bound(uint256(rawCount), 1, 12);
        for (uint256 i; i < count; i++) {
            frog.setTarget(type(uint256).max);
            mintOne(alice);
        }
        uint256 tokens = uint256(rawTokens);
        uint256 pair = uint256(rawIMD);
        tokens = bound(tokens, 0, 1e26);
        pair = bound(pair, 0, 1e26);
        token.transfer(address(frog), tokens);
        imd.transfer(address(frog), pair);
        for (uint256 id = 1; id <= count; id++) {
            uint256 expectedToken = token.balanceOf(address(frog)) / (count - id + 1);
            uint256 expectedPair = imd.balanceOf(address(frog)) / (count - id + 1);
            uint256 tb = token.balanceOf(alice);
            uint256 ib = imd.balanceOf(alice);
            vm.prank(alice);
            frog.burn(id);
            assertEq(token.balanceOf(alice) - tb, expectedToken);
            assertEq(imd.balanceOf(alice) - ib, expectedPair);
            assertEq(token.balanceOf(alice) + token.balanceOf(address(frog)), tokens);
            assertEq(imd.balanceOf(alice) + imd.balanceOf(address(frog)), pair);
        }
        assertEq(token.balanceOf(address(frog)), 0);
        assertEq(imd.balanceOf(address(frog)), 0);
    }

    function testForcedEthOnlyGoesToFixedRecipients() public {
        uint256 hackBefore = frog.HACKATHON().balance;
        uint256 teamBefore = frog.TEAM().balance;
        vm.deal(address(frog), 101);
        vm.prank(bob);
        frog.flush();
        assertEq(frog.HACKATHON().balance - hackBefore, 85);
        assertEq(frog.TEAM().balance - teamBefore, 16);
        assertEq(address(frog).balance, 0);
    }

    function testBurnExactShareDustAndHolderOnly() public {
        mintOne(alice);
        mintOne(alice);
        mintOne(bob);
        token.transfer(address(frog), 101);
        imd.transfer(address(frog), 10);
        (uint256 t, uint256 i) = frog.burnQuote();
        assertEq(t, 33);
        assertEq(i, 3);
        vm.prank(alice);
        frog.approve(bob, 1);
        vm.prank(bob);
        vm.expectRevert(HashFrog.HolderOnly.selector);
        frog.burn(1);
        vm.prank(alice);
        frog.burn(1);
        assertEq(token.balanceOf(alice), 33);
        assertEq(imd.balanceOf(alice), 3);
        vm.prank(alice);
        frog.burn(2);
        assertEq(token.balanceOf(alice), 67);
        assertEq(imd.balanceOf(alice), 6);
        vm.prank(bob);
        frog.burn(3);
        assertEq(token.balanceOf(bob), 34);
        assertEq(imd.balanceOf(bob), 4);
        assertEq(token.balanceOf(address(frog)), 0);
        assertEq(imd.balanceOf(address(frog)), 0);
        assertEq(frog.liveSupply(), 0);
        vm.prank(bob);
        vm.expectRevert();
        frog.burn(3);
        vm.expectRevert();
        frog.tokenURI(1);
        assertEq(mintOne(alice), 4, "burned identifiers never reused");
    }

    function testNoWithdrawalOrAdminSelectors() public {
        token.transfer(address(frog), 1000);
        imd.transfer(address(frog), 1000);
        string[6] memory calls = [
            "withdraw()",
            "withdraw(address,uint256)",
            "rescue(address,uint256)",
            "pause()",
            "upgradeTo(address)",
            "transferOwnership(address)"
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(bob);
            (bool ok,) = address(frog).call(abi.encodeWithSignature(calls[i], bob, 1000));
            assertFalse(ok);
        }
        assertEq(token.balanceOf(address(frog)), 1000);
        assertEq(imd.balanceOf(address(frog)), 1000);
    }

    function testRetargetHarderEasierAndSaturation() public {
        uint256 initial = 1 << 248;
        frog.setTarget(initial);
        // Set a known easy target for mining, then restore the starting target just for the eighth mint
        // and solve against that real target. The eighth mint applies the retarget formula.
        for (uint256 i; i < 7; ++i) {
            frog.setTarget(type(uint256).max);
            mintOne(alice);
        }
        frog.setTarget(initial);
        _solveAndMint(alice);
        assertEq(frog.target(), initial / 4);
        vm.warp(vm.getBlockTimestamp() + 10000);
        for (uint256 i; i < 7; ++i) {
            frog.setTarget(type(uint256).max);
            mintOne(alice);
        }
        frog.setTarget(initial);
        _solveAndMint(alice);
        assertEq(frog.target(), initial * 2);
        vm.warp(vm.getBlockTimestamp() + 10000);
        for (uint256 i; i < 8; ++i) {
            frog.setTarget(type(uint256).max);
            mintOne(alice);
        }
        assertEq(frog.target(), type(uint256).max);
    }

    function _solveAndMint(address who) internal {
        frog.nextTransaction();
        bytes32 seed = frog.lastSeed();
        uint256 t = frog.target();
        uint256 nonce;
        while (uint256(keccak256(abi.encodePacked(who, nonce, seed, refHash))) >= t) nonce++;
        vm.prank(who);
        frog.mine{value: PRICE}(nonce, seed, 99);
    }

    function testProductionDifficultyAndGenesis() public {
        HashFrog actual = new HashFrog(manager, token, imd, FrogRouter(address(0)), address(0));
        assertEq(actual.target(), type(uint256).max >> 20);
        assertEq(actual.lastSeed(), actual.GENESIS_SEED());
        // A precomputed main-algorithm proof, verified at the real fixed launch difficulty.
        uint256 nonce = 729977;
        bytes32 seed = actual.lastSeed();
        assertLt(uint256(keccak256(abi.encodePacked(alice, nonce, seed, refHash))), actual.target());
        vm.prank(alice);
        actual.mine{value: PRICE}(nonce, seed, 99);
        assertEq(actual.ownerOf(1), alice);
        assertTrue(bytes(actual.tokenURI(1)).length > 5000);
    }

    function testERC721CallbackCannotReenterPayments() public {
        ReenterMint receiver = new ReenterMint(frog);
        receiver.go{value: PRICE}(frog.lastSeed(), 99);
        assertTrue(receiver.blocked());
        assertEq(frog.totalMinted(), 1);
    }
}
