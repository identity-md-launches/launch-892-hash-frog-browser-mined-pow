// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FrogHarness, RejectETH} from "./NFT.t.sol";
import {HashFrog} from "src/HashFrog.sol";
import {HFROG} from "src/HFROG.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Only difficulty and the test's transaction boundary are controlled by the harness.
/// Supply, ownership, proof hashing, rolling admission and all payments use production code.
contract NFTSequenceHandler is Test {
    FrogHarness public frog;
    HFROG public token;
    MockERC20 public imd;
    address[3] public actors = [address(0x1101), address(0x2202), address(0x3303)];
    uint256[] public times;
    uint256[] public liveIds;
    mapping(uint256 => address) public owners;
    uint256 public burned;
    uint256 public donatedToken;
    uint256 public donatedIMD;
    uint256 public paidToken;
    uint256 public paidIMD;
    uint256 public forcedETH;
    uint256 public unallocatedETH;
    uint256 public expectedHackathon;
    uint256 public expectedTeam;
    bytes private rejectCode;

    constructor(FrogHarness f, HFROG t, MockERC20 i) {
        frog = f;
        token = t;
        imd = i;
        rejectCode = address(new RejectETH()).code;
        for (uint256 j; j < 3; ++j) {
            vm.deal(actors[j], 100 ether);
        }
    }

    function mint(uint8 who) public {
        frog.nextTransaction();
        frog.setTarget(type(uint256).max);
        uint256 refBlock = vm.getBlockNumber() - 1;
        vm.setBlockhash(refBlock, keccak256(abi.encode(refBlock)));
        address actor = actors[who % 3];
        bytes32 seed = frog.lastSeed();
        uint256 count = times.length;
        vm.prank(actor);
        if (count == 2000) {
            vm.expectRevert(HashFrog.SoldOut.selector);
            frog.mine{value: 0.0019 ether}(0, seed, refBlock);
            return;
        }
        if (count >= 60 && vm.getBlockTimestamp() < times[count - 60] + 3600) {
            vm.expectRevert(abi.encodeWithSelector(HashFrog.HourFull.selector, times[count - 60] + 3600));
            frog.mine{value: 0.0019 ether}(0, seed, refBlock);
            return;
        }
        uint256 id = frog.mine{value: 0.0019 ether}(0, seed, refBlock);
        assertEq(id, count + 1, "IDs cannot be recycled after burns");
        owners[id] = actor;
        times.push(vm.getBlockTimestamp());
        liveIds.push(id);
        expectedHackathon += 0.001615 ether;
        expectedTeam += 0.000285 ether;
    }

    function burn(uint256 pick) public {
        if (liveIds.length == 0) return;
        uint256 index = pick % liveIds.length;
        uint256 id = liveIds[index];
        address actor = owners[id];
        uint256 expectedToken = token.balanceOf(address(frog)) / liveIds.length;
        uint256 expectedIMD = imd.balanceOf(address(frog)) / liveIds.length;
        uint256 tokenBefore = token.balanceOf(actor);
        uint256 imdBefore = imd.balanceOf(actor);
        vm.prank(actor);
        (uint256 receivedToken, uint256 receivedIMD) = frog.burn(id);
        assertEq(receivedToken, expectedToken);
        assertEq(receivedIMD, expectedIMD);
        assertEq(token.balanceOf(actor) - tokenBefore, expectedToken);
        assertEq(imd.balanceOf(actor) - imdBefore, expectedIMD);
        paidToken += expectedToken;
        paidIMD += expectedIMD;
        burned++;
        delete owners[id];
        liveIds[index] = liveIds[liveIds.length - 1];
        liveIds.pop();
        vm.prank(actor);
        vm.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", id));
        frog.burn(id);
    }

    function transferFrog(uint256 pick, uint8 who) public {
        if (liveIds.length == 0) return;
        uint256 id = liveIds[pick % liveIds.length];
        address to = actors[who % 3];
        vm.prank(owners[id]);
        frog.transferFrom(owners[id], to, id);
        owners[id] = to;
    }

    function unauthorizedBurn(uint256 pick) public {
        if (liveIds.length == 0) return;
        uint256 id = liveIds[pick % liveIds.length];
        address attacker = address(0xBAD);
        vm.prank(owners[id]);
        frog.approve(attacker, id);
        vm.prank(attacker);
        vm.expectRevert(HashFrog.HolderOnly.selector);
        frog.burn(id);
        assertEq(frog.ownerOf(id), owners[id]);
        assertEq(token.balanceOf(attacker), 0);
        assertEq(imd.balanceOf(attacker), 0);
    }

    function donate(uint96 t, uint96 i) public {
        uint256 a = bound(uint256(t), 0, 1000 ether);
        uint256 b = bound(uint256(i), 0, 1000 ether);
        token.transfer(address(frog), a);
        imd.transfer(address(frog), b);
        donatedToken += a;
        donatedIMD += b;
    }

    function forceETH(uint96 raw) public {
        uint256 amount = bound(uint256(raw), 0, 1 ether);
        vm.deal(address(frog), address(frog).balance + amount);
        forcedETH += amount;
        unallocatedETH += amount;
    }

    function recipientFailures(bool hackRejects, bool teamRejects) public {
        vm.etch(frog.HACKATHON(), hackRejects ? rejectCode : bytes(""));
        vm.etch(frog.TEAM(), teamRejects ? rejectCode : bytes(""));
    }

    function flush(uint8 who) public {
        address actor = actors[who % 3];
        uint256 beforeBalance = actor.balance;
        vm.prank(actor);
        frog.flush();
        uint256 hackShare = unallocatedETH * 85 / 100;
        expectedHackathon += hackShare;
        expectedTeam += unallocatedETH - hackShare;
        unallocatedETH = 0;
        assertEq(actor.balance, beforeBalance, "flusher cannot redirect ETH");
    }

    function advance(uint32 seconds_) public {
        vm.warp(vm.getBlockTimestamp() + bound(uint256(seconds_), 0, 3601));
        vm.roll(vm.getBlockNumber() + 1);
    }

    function minted() external view returns (uint256) {
        return times.length;
    }

    function alive() external view returns (uint256) {
        return liveIds.length;
    }

    function recent() public view returns (uint256 count, uint256 next) {
        for (uint256 j = times.length; j > 0; --j) {
            uint256 expiry = times[j - 1] + 3600;
            if (expiry <= vm.getBlockTimestamp()) break;
            count++;
            next = expiry;
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract NFTStatefulTest is Test {
    FrogHarness frog;
    HFROG token;
    MockERC20 imd;
    NFTSequenceHandler handler;

    function setUp() public {
        vm.warp(1_000_000);
        vm.roll(100);
        PoolManager manager = new PoolManager(address(this));
        token = new HFROG();
        imd = new MockERC20("IdentityMD", "IMD", 1e30);
        frog = new FrogHarness(manager, token, imd);
        vm.deal(frog.HACKATHON(), 0);
        vm.deal(frog.TEAM(), 0);
        handler = new NFTSequenceHandler(frog, token, imd);
        token.transfer(address(handler), 1_000_000 ether);
        imd.transfer(address(handler), 1_000_000 ether);
        // Start with real liabilities and a burn so conservation is never vacuous.
        handler.recipientFailures(true, false);
        handler.mint(0);
        handler.mint(1);
        handler.donate(101, 17);
        handler.burn(0);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.mint.selector;
        selectors[1] = handler.burn.selector;
        selectors[2] = handler.transferFrog.selector;
        selectors[3] = handler.unauthorizedBurn.selector;
        selectors[4] = handler.donate.selector;
        selectors[5] = handler.forceETH.selector;
        selectors[6] = handler.recipientFailures.selector;
        selectors[7] = handler.flush.selector;
        selectors[8] = handler.advance.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_ETHIsPaidOrBacksCredits() public view {
        uint256 paid = frog.HACKATHON().balance + frog.TEAM().balance;
        assertEq(paid + address(frog).balance, handler.minted() * 0.0019 ether + handler.forcedETH());
        assertEq(frog.ethToHackathon(), frog.HACKATHON().balance);
        assertEq(frog.ethToTeam(), frog.TEAM().balance);
        assertEq(
            frog.ethCredit(frog.HACKATHON()) + frog.ethCredit(frog.TEAM()) + handler.unallocatedETH(),
            address(frog).balance
        );
        assertEq(frog.ethToHackathon() + frog.ethCredit(frog.HACKATHON()), handler.expectedHackathon());
        assertEq(frog.ethToTeam() + frog.ethCredit(frog.TEAM()), handler.expectedTeam());
    }

    function invariant_VaultPaysOnlyExactBurnShares() public view {
        assertEq(token.balanceOf(address(frog)) + handler.paidToken(), handler.donatedToken());
        assertEq(imd.balanceOf(address(frog)) + handler.paidIMD(), handler.donatedIMD());
        uint256 receivedToken;
        uint256 receivedIMD;
        for (uint256 j; j < 3; ++j) {
            receivedToken += token.balanceOf(handler.actors(j));
            receivedIMD += imd.balanceOf(handler.actors(j));
        }
        assertEq(receivedToken, handler.paidToken());
        assertEq(receivedIMD, handler.paidIMD());
        assertEq(token.balanceOf(address(handler)) + handler.donatedToken(), 1_000_000 ether);
        assertEq(imd.balanceOf(address(handler)) + handler.donatedIMD(), 1_000_000 ether);
    }

    function invariant_MintHistoryAndOwnershipAgree() public view {
        assertEq(frog.totalMinted(), handler.minted());
        assertEq(frog.totalBurned(), handler.burned());
        assertEq(frog.liveSupply(), handler.alive());
        assertLe(frog.totalMinted(), 2000);
        uint256 balances;
        for (uint256 j; j < 3; ++j) {
            balances += frog.balanceOf(handler.actors(j));
        }
        assertEq(balances, handler.alive());
        for (uint256 j; j < handler.alive(); ++j) {
            uint256 id = handler.liveIds(j);
            assertEq(frog.ownerOf(id), handler.owners(id));
        }
        (uint256 used, uint256 next) = handler.recent();
        (uint256 available, uint256 advertisedNext) = frog.freeSlots();
        assertLe(used, 60, "rolling hour exceeds cap");
        assertEq(available, handler.minted() == 2000 ? 0 : 60 - used);
        assertEq(advertisedNext, next);
    }

    function test_HandlerExercisesFullWindowBurnTransferAndRetry() public {
        for (uint256 j = 2; j < 60; ++j) {
            handler.mint(uint8(j));
        }
        handler.burn(0);
        handler.mint(0); // Burning does not reopen the rolling window.
        handler.advance(3599);
        handler.mint(0);
        handler.advance(1);
        handler.mint(2);
        handler.transferFrog(0, 2);
        handler.unauthorizedBurn(0);
        handler.forceETH(101);
        handler.flush(0);
        handler.recipientFailures(false, false);
        handler.flush(1);
        handler.flush(1);
        invariant_ETHIsPaidOrBacksCredits();
        invariant_VaultPaysOnlyExactBurnShares();
        invariant_MintHistoryAndOwnershipAgree();
    }
}
