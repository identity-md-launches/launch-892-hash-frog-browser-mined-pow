// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Fixture} from "./helpers/Fixture.sol";
import {Test} from "forge-std/Test.sol";
import {HFROG} from "../src/HFROG.sol";
import {HashFrog} from "../src/HashFrog.sol";
import {FrogRouter} from "../src/FrogRouter.sol";
import {FrogStaking} from "../src/FrogStaking.sol";
import {HashFrogHook} from "../src/HashFrogHook.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract PondHandler is Test {
    HFROG public token;
    MockERC20 public imd;
    HashFrogHook public hook;
    FrogStaking public staking;
    HashFrog public frog;
    FrogRouter public router;
    address[3] public actors = [address(0x11), address(0x22), address(0x33)];

    constructor(HashFrogHook h) {
        hook = h;
        token = HFROG(address(h.hfrog()));
        imd = MockERC20(address(h.imd()));
        staking = h.staking();
        frog = h.frog();
        router = h.router();
        token.approve(address(router), type(uint256).max);
        imd.approve(address(router), type(uint256).max);
        for (uint256 i; i < 3; i++) {
            vm.prank(actors[i]);
            token.approve(address(staking), type(uint256).max);
        }
    }

    function stake(uint8 who, uint96 raw) external {
        address a = actors[who % 3];
        uint256 balance = token.balanceOf(a);
        if (balance == 0) return;
        vm.prank(a);
        staking.stake(bound(uint256(raw), 1, balance));
    }

    function requestExit(uint8 who, uint96 raw) external {
        address a = actors[who % 3];
        (uint256 active,,,,) = staking.positions(a);
        if (active == 0) return;
        vm.prank(a);
        staking.requestUnstake(bound(uint256(raw), 1, active));
    }

    function claim(uint8 who) external {
        vm.prank(actors[who % 3]);
        staking.claim();
    }

    function unstake(uint8 who) external {
        vm.prank(actors[who % 3]);
        staking.unstake();
    }

    function swap(bool buy, uint96 raw) external {
        router.swap(buy, bound(uint256(raw), 1e8, 10 ether), 1, 0, vm.getBlockTimestamp());
    }

    function advance(uint32 raw) external {
        vm.warp(vm.getBlockTimestamp() + bound(uint256(raw), 1, 2 days));
    }

    function redeem() external {
        frog.redeemFees();
        hook.redeemFees();
        staking.redeemFees();
    }

    function buyback(uint96 raw) external {
        uint256 available = imd.balanceOf(address(frog)) + frog.pendingFees();
        if (available == 0) return;
        uint256 amount = bound(uint256(raw), 1, available > 100 ether ? 100 ether : available);
        uint256 floor = hook.quoteAtTick(hook.consult(), uint128(amount), address(imd) < address(token)) * 95 / 100;
        frog.buyback(amount, floor, 0, vm.getBlockTimestamp());
    }
}

contract AccountingInvariantTest is Fixture {
    PondHandler handler;

    function setUp() public override {
        super.setUp();
        seedPool();
        handler = new PondHandler(hook);
        token.transfer(address(handler), 1_000_000 ether);
        imd.transfer(address(handler), 1_000_000 ether);
        for (uint256 i; i < 3; i++) {
            token.transfer(handler.actors(i), 10000 ether);
        }
        targetContract(address(handler));
    }

    function invariantFeeConservationAndNoRecipientSubstitution() public view {
        assertEq(hook.totalFees(), hook.totalToStakers() + hook.totalToVault() + hook.totalToTeam());
        assertEq(hook.totalToTeam(), hook.pendingFees() + imd.balanceOf(hook.TEAM()));
        assertEq(hook.totalToVault(), frog.pendingFees() + imd.balanceOf(address(frog)) + frog.totalBuybackIMD());
        assertEq(
            hook.totalToStakers(), staking.pendingFees() + imd.balanceOf(address(staking)) + staking.totalClaimed()
        );
        assertEq(staking.totalRewards(), hook.totalToStakers());
        assertLe(staking.totalClaimed(), staking.totalRewards());
        assertEq(token.balanceOf(address(frog)), frog.totalBoughtHFROG());
    }

    function invariantPrincipalAndPendingRewardsStaySolvent() public view {
        uint256 active;
        uint256 exiting;
        uint256 earned;
        for (uint256 i; i < 3; i++) {
            (uint256 a, uint256 e,,,) = staking.positions(handler.actors(i));
            active += a;
            exiting += e;
            earned += staking.earned(handler.actors(i));
        }
        assertEq(active, staking.totalStaked());
        assertEq(active + exiting, token.balanceOf(address(staking)));
        assertLe(earned, staking.pendingFees() + imd.balanceOf(address(staking)));
    }
}
