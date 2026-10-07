// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Fixture} from "./helpers/Fixture.sol";
import {FrogStaking} from "../src/FrogStaking.sol";

contract StakingTest is Fixture {
    function testRewardsAccrueAtSwapAndConserve() public {
        seedPool();
        token.transfer(alice, 100 ether);
        token.transfer(bob, 300 ether);
        vm.prank(alice);
        token.approve(address(staking), 100 ether);
        vm.prank(bob);
        token.approve(address(staking), 300 ether);
        vm.prank(alice);
        staking.stake(100 ether);
        vm.prank(bob);
        staking.stake(300 ether);
        trade(true, true, 100 ether);
        assertEq(staking.earned(alice), 0.225 ether);
        assertEq(staking.earned(bob), 0.675 ether);
        vm.prank(alice);
        staking.claim();
        vm.prank(bob);
        staking.claim();
        assertEq(imd.balanceOf(alice), 0.225 ether);
        assertEq(imd.balanceOf(bob), 0.675 ether);
        assertEq(staking.totalClaimed(), hook.totalToStakers());
        assertEq(imd.balanceOf(address(staking)), 0);
        vm.prank(alice);
        assertEq(staking.claim(), 0);
    }

    function testEmptyRewardsGoToFirstStakerAndExitStopsEarnings() public {
        seedPool();
        trade(true, true, 100 ether);
        assertEq(staking.queuedRewards(), 0.9 ether);
        staking.stake(100 ether);
        assertEq(staking.earned(address(this)), 0.9 ether);
        staking.requestUnstake(100 ether);
        assertEq(staking.totalStaked(), 0);
        trade(true, true, 100 ether);
        assertEq(staking.earned(address(this)), 0.9 ether);
        token.transfer(alice, 100 ether);
        vm.prank(alice);
        token.approve(address(staking), 100 ether);
        vm.prank(alice);
        staking.stake(100 ether);
        assertEq(staking.earned(alice), 0.9 ether);
        vm.expectRevert();
        staking.unstake();
        vm.warp(vm.getBlockTimestamp() + 24 hours - 1);
        vm.expectRevert();
        staking.unstake();
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(staking.unstake(), 100 ether);
        vm.expectRevert(FrogStaking.InvalidAmount.selector);
        staking.unstake();
        uint256 before = imd.balanceOf(address(this));
        staking.claim();
        assertEq(imd.balanceOf(address(this)) - before, 0.9 ether);
        vm.prank(alice);
        staking.claim();
        assertEq(staking.totalClaimed(), staking.totalRewards());
    }

    function testLateStakeCannotCaptureAlreadyAccruedRewards() public {
        seedPool();
        staking.stake(100 ether);
        trade(true, true, 100 ether);
        token.transfer(alice, 100 ether);
        vm.prank(alice);
        token.approve(address(staking), 100 ether);
        vm.prank(alice);
        staking.stake(100 ether);
        assertEq(staking.earned(alice), 0);
        assertEq(staking.earned(address(this)), 0.9 ether);
        vm.prank(alice);
        staking.redeemFees();
        assertEq(staking.earned(alice), 0);
        staking.claim();
        assertEq(staking.totalClaimed(), 0.9 ether);
    }

    function testPartialExitAndAdditionalExitRestartsDelay() public {
        staking.stake(100 ether);
        staking.requestUnstake(20 ether);
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        staking.requestUnstake(10 ether);
        (uint256 active, uint256 exiting, uint256 unlockAt,,) = staking.positions(address(this));
        assertEq(active, 70 ether);
        assertEq(exiting, 30 ether);
        assertEq(unlockAt, vm.getBlockTimestamp() + 24 hours);
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        vm.expectRevert();
        staking.unstake();
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        assertEq(staking.unstake(), 30 ether);
    }

    function testUnauthorizedNotificationInvalidAmountsAndExcessExit() public {
        vm.expectRevert(FrogStaking.OnlyHook.selector);
        staking.notifyReward(1 ether);
        vm.expectRevert(FrogStaking.InvalidAmount.selector);
        staking.stake(0);
        vm.expectRevert(FrogStaking.InvalidAmount.selector);
        staking.requestUnstake(1);
        vm.expectRevert(FrogStaking.InvalidAmount.selector);
        staking.unstake();
    }

    function testFuzzRoundingNeverOverpays(uint96 a, uint96 b, uint96 rawFee) public {
        uint256 sa = bound(uint256(a), 1, 1e25);
        uint256 sb = bound(uint256(b), 1, 1e25);
        uint256 input = bound(uint256(rawFee), 1e8, 1000 ether);
        seedPool();
        token.transfer(alice, sa);
        token.transfer(bob, sb);
        vm.prank(alice);
        token.approve(address(staking), sa);
        vm.prank(alice);
        staking.stake(sa);
        vm.prank(bob);
        token.approve(address(staking), sb);
        vm.prank(bob);
        staking.stake(sb);
        trade(true, true, input);
        vm.prank(alice);
        staking.claim();
        vm.prank(bob);
        staking.claim();
        assertLe(staking.totalClaimed(), hook.totalToStakers());
        assertLe(hook.totalToStakers() - staking.totalClaimed(), 2);
        assertEq(imd.balanceOf(address(staking)) + staking.totalClaimed(), hook.totalToStakers());
        assertEq(token.balanceOf(address(staking)), sa + sb);
    }
}
