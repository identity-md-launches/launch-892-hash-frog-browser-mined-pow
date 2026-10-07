// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {HashFrog} from "src/HashFrog.sol";
import {FrogStaking} from "src/FrogStaking.sol";
import {FrogRouter} from "src/FrogRouter.sol";
import {ClaimReceiver} from "src/ClaimReceiver.sol";
import {HashFrogHook} from "src/HashFrogHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

abstract contract FeePropertyBase is Fixture {
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_EachOrderChargesOnlyIMDAndConservesSplit(bool buy, bool exactInput, uint96 raw) public {
        seedPool();
        uint256 amount = bound(uint256(raw), 100, 10_000 ether);
        uint256 imdBefore = imd.balanceOf(address(this));
        uint256 tokenBefore = token.balanceOf(address(this));
        BalanceDelta d = trade(buy, exactInput, amount);
        int256 pairDelta = int256(imdDelta(d));
        int256 frogDelta = int256(address(imd) < address(token) ? d.amount1() : d.amount0());
        assertEq(int256(imd.balanceOf(address(this))) - int256(imdBefore), pairDelta);
        assertEq(int256(token.balanceOf(address(this))) - int256(tokenBefore), frogDelta);
        assertTrue(buy ? pairDelta < 0 && frogDelta > 0 : pairDelta > 0 && frogDelta < 0);
        if (buy == exactInput) {
            assertEq(uint256(pairDelta < 0 ? -pairDelta : pairDelta), amount);
        } else {
            assertEq(uint256(frogDelta < 0 ? -frogDelta : frogDelta), amount);
        }

        uint256 fee = hook.totalFees();
        // Buy exact-input uses the gross IMD budget. Other modes charge on the
        // pool's actual IMD leg, reconstructed from the trader's net movement.
        uint256 basis = buy ? uint256(-pairDelta) : uint256(pairDelta) + fee;
        if (buy && !exactInput) basis -= fee;
        assertEq(fee, basis * 150 / 10_000);
        uint256 stakerFee = fee * 60 / 100;
        uint256 vaultFee = fee * 25 / 100;
        uint256 teamFee = fee - stakerFee - vaultFee;
        assertEq(staking.pendingFees(), stakerFee);
        assertEq(frog.pendingFees(), vaultFee);
        assertEq(hook.pendingFees(), teamFee);
        assertEq(staking.totalRewards(), stakerFee);
        assertEq(staking.queuedRewards(), stakerFee);
        assertEq(hook.totalToStakers(), stakerFee);
        assertEq(hook.totalToVault(), vaultFee);
        assertEq(hook.totalToTeam(), teamFee);
        vm.startPrank(bob);
        frog.redeemFees();
        staking.redeemFees();
        hook.redeemFees();
        vm.stopPrank();
        assertEq(imd.balanceOf(address(frog)), vaultFee);
        assertEq(imd.balanceOf(address(staking)), stakerFee);
        assertEq(imd.balanceOf(hook.TEAM()), teamFee);
        assertEq(imd.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(hook)) + token.balanceOf(address(router)), 0);
    }
}

/// forge-config: default.fuzz.runs = 1000
contract FeePropertiesIMD0Test is FeePropertyBase {
    function deployAssets() internal override {
        super.deployAssets();
        while (address(imd) > address(token)) imd = new MockERC20("IdentityMD", "IMD", 1e30);
    }
}

/// forge-config: default.fuzz.runs = 1000
contract FeePropertiesIMD1Test is FeePropertyBase {
    function deployAssets() internal override {
        super.deployAssets();
        while (address(imd) < address(token)) imd = new MockERC20("IdentityMD", "IMD", 1e30);
    }
}

contract AdversarialFlowsTest is Fixture {
    using StateLibrary for IPoolManager;

    function test_ImmutableRecipientsAndCompanionsMatchTheLaunch() public view {
        assertEq(frog.HACKATHON(), 0x56e8C9Bd511718508f7410aEE3E8A693588B38F0);
        assertEq(frog.TEAM(), 0x789C9aDDa69a5880fe70eb4FBC8147F2a54B6363);
        assertEq(hook.TEAM(), frog.TEAM());
        assertEq(hook.redemptionRecipient(), frog.TEAM());
        assertEq(frog.redemptionRecipient(), address(frog));
        assertEq(staking.redemptionRecipient(), address(staking));
        assertEq(address(frog.hfrog()), address(token));
        assertEq(address(staking.hfrog()), address(token));
        assertEq(address(router.hfrog()), address(token));
        assertEq(address(frog.imd()), address(imd));
        assertEq(address(staking.imd()), address(imd));
        assertEq(address(router.imd()), address(imd));
        assertEq(address(frog.poolManager()), address(manager));
        assertEq(address(staking.poolManager()), address(manager));
        assertEq(address(router.poolManager()), address(manager));
        assertEq(frog.hook(), address(hook));
        assertEq(staking.hook(), address(hook));
        assertEq(router.hook(), address(hook));
        assertEq(address(frog.router()), address(router));
        assertEq(keccak256(abi.encode(router.poolKey())), keccak256(abi.encode(key)));
        assertEq(key.fee, 12500);
    }

    function test_CommonAdminAndWithdrawalCallsCannotReleaseFunds() public {
        seedPool();
        staking.stake(100 ether);
        trade(true, true, 100 ether);
        token.transfer(address(frog), 10 ether);
        frog.redeemFees();
        staking.redeemFees();
        bytes32 beforeState = snapshotAccounting();
        address[5] memory targets = [address(token), address(hook), address(frog), address(staking), address(router)];
        string[8] memory signatures = [
            "withdraw()",
            "withdraw(address,uint256)",
            "rescue(address,uint256)",
            "sweep(address,address)",
            "pause()",
            "upgradeTo(address)",
            "transferOwnership(address)",
            "mint(address,uint256)"
        ];
        for (uint256 j; j < targets.length; ++j) {
            for (uint256 k; k < signatures.length; ++k) {
                for (uint256 caller; caller < 2; ++caller) {
                    vm.prank(caller == 0 ? address(this) : bob);
                    (bool ok,) = targets[j].call(abi.encodeWithSignature(signatures[k], bob, 1 ether));
                    assertFalse(ok, signatures[k]);
                }
            }
        }
        assertEq(snapshotAccounting(), beforeState);
        assertEq(imd.balanceOf(bob) + token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(staking)), 100 ether);
        assertEq(imd.balanceOf(address(staking)), 0.9 ether);
    }

    function snapshotAccounting() internal view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) =
            IPoolManager(address(manager)).getSlot0(key.toId());
        bytes32 poolState = keccak256(
            abi.encode(
                price, tick, protocolFee, lpFee, imd.balanceOf(address(manager)), token.balanceOf(address(manager))
            )
        );
        bytes32 feeState = keccak256(
            abi.encode(
                hook.totalFees(),
                hook.totalToStakers(),
                hook.totalToVault(),
                hook.totalToTeam(),
                hook.pendingFees(),
                frog.pendingFees(),
                staking.pendingFees(),
                staking.totalRewards(),
                staking.rewardPerToken(),
                staking.queuedRewards(),
                hook.tickCumulative(),
                hook.lastObservationTime(),
                hook.observationIndex()
            )
        );
        bytes32 vaultState = keccak256(
            abi.encode(
                frog.lastBuyback(),
                frog.totalBuybackIMD(),
                frog.totalBoughtHFROG(),
                frog.totalRedeemed(),
                imd.balanceOf(address(frog)),
                token.balanceOf(address(frog)),
                imd.allowance(address(frog), address(router))
            )
        );
        return keccak256(
            abi.encode(
                poolState,
                feeState,
                vaultState,
                imd.balanceOf(address(this)),
                token.balanceOf(address(this)),
                imd.balanceOf(address(router)),
                token.balanceOf(address(router))
            )
        );
    }

    function test_FailedSwapRestoresPoolClaimsRewardsAndBalances() public {
        seedPool();
        staking.stake(13 ether);
        trade(true, true, 100 ether);
        bytes32 beforeState = snapshotAccounting();
        vm.expectRevert(FrogRouter.Slippage.selector);
        router.swap(true, 10 ether, type(uint128).max, 0, vm.getBlockTimestamp());
        assertEq(snapshotAccounting(), beforeState);
        // This failure occurs during settlement, after hook callbacks have run.
        imd.approve(address(router), 0);
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientAllowance(address,uint256,uint256)", address(router), 0, 10 ether)
        );
        router.swap(true, 10 ether, 1, 0, vm.getBlockTimestamp());
        assertEq(snapshotAccounting(), beforeState);
    }

    function test_QuotesBothWaysCannotAccrueRewardsOrConsumeFunds() public {
        seedPool();
        staking.stake(7 ether);
        trade(true, true, 100 ether);
        bytes32 beforeState = snapshotAccounting();
        for (uint256 j; j < 2; ++j) {
            bool buy = j == 0;
            vm.prank(bob); // Unfunded, with no allowance.
            (uint256 spent, uint256 received) = router.quote(buy, 10 ether, 0);
            assertEq(spent, 10 ether);
            assertGt(received, 0);
            assertEq(snapshotAccounting(), beforeState);
        }
    }

    function test_BuybackFailuresRestoreCooldownClaimsAllowanceAndPool() public {
        seedPool();
        trade(true, true, 1000 ether);
        vm.warp(vm.getBlockTimestamp() + 1800);
        bytes32 beforeState = snapshotAccounting();
        vm.expectRevert(HashFrog.InvalidBuybackAmount.selector);
        frog.buyback(0, 1, 0, vm.getBlockTimestamp());
        assertEq(snapshotAccounting(), beforeState);
        vm.expectRevert(HashFrog.InvalidBuybackAmount.selector);
        frog.buyback(100 ether + 1, 100 ether, 0, vm.getBlockTimestamp());
        assertEq(snapshotAccounting(), beforeState);
        // This reaches claim redemption before finding the vault is too small.
        vm.expectRevert(HashFrog.InvalidBuybackAmount.selector);
        frog.buyback(100 ether, 100 ether, 0, vm.getBlockTimestamp());
        assertEq(snapshotAccounting(), beforeState);
        vm.expectRevert(FrogRouter.Expired.selector);
        frog.buyback(1 ether, 1 ether, 0, vm.getBlockTimestamp() - 1);
        assertEq(snapshotAccounting(), beforeState);
        vm.expectRevert(FrogRouter.Slippage.selector);
        frog.buyback(1 ether, 1000 ether, 0, vm.getBlockTimestamp());
        assertEq(snapshotAccounting(), beforeState);
        assertGt(frog.pendingFees(), 0, "failed buyback must restore unredeemed claims");
    }

    function test_BuybackThenBurnRedeemsFreshClaimsAndLeavesNoDust() public {
        seedPool();
        trade(true, true, 1000 ether);
        vm.setBlockhash(99, keccak256("reference"));
        vm.deal(alice, 1 ether);
        bytes32 seed = frog.lastSeed();
        vm.prank(alice);
        frog.mine{value: 0.0019 ether}(729977, seed, 99);
        vm.warp(vm.getBlockTimestamp() + 1800);
        uint256 floor = hook.quoteAtTick(hook.consult(), 1 ether, address(imd) < address(token)) * 95 / 100;
        vm.prank(bob);
        uint256 bought = frog.buyback(1 ether, floor, 0, vm.getBlockTimestamp());
        assertGt(bought, 0);
        assertEq(token.balanceOf(bob), 0, "permissionless caller cannot take buyback output");
        assertEq(imd.balanceOf(bob), 0);
        assertEq(imd.allowance(address(frog), address(router)), 0);
        assertGt(frog.pendingFees(), 0, "buyback itself earns new vault claims");
        uint256 expectedIMD = imd.balanceOf(address(frog)) + frog.pendingFees();
        vm.prank(alice);
        (uint256 burnedToken, uint256 burnedIMD) = frog.burn(1);
        assertEq(burnedToken, bought);
        assertEq(burnedIMD, expectedIMD);
        assertEq(token.balanceOf(alice), bought);
        assertEq(imd.balanceOf(alice), expectedIMD);
        assertEq(imd.balanceOf(address(frog)) + frog.pendingFees(), 0);
        assertEq(token.balanceOf(address(frog)), 0);
        assertEq(frog.totalBuybackIMD() + burnedIMD, hook.totalToVault());
        (uint256 t, uint256 i) = frog.burnQuote();
        assertEq(t + i, 0);
    }

    function test_AllClaimReceiversRejectSpoofedAndUnsolicitedUnlocks() public {
        seedPool();
        trade(true, true, 100 ether);
        ClaimReceiver[3] memory receivers =
            [ClaimReceiver(address(hook)), ClaimReceiver(address(frog)), ClaimReceiver(address(staking))];
        bytes32 beforeState = snapshotAccounting();
        for (uint256 j; j < 3; ++j) {
            vm.prank(bob);
            vm.expectRevert(ClaimReceiver.OnlyPoolManager.selector);
            receivers[j].unlockCallback(abi.encode(type(uint256).max));
            vm.prank(address(manager));
            vm.expectRevert(ClaimReceiver.UnexpectedUnlock.selector);
            receivers[j].unlockCallback(abi.encode(1 ether));
        }
        vm.prank(address(manager));
        vm.expectRevert(FrogRouter.UnexpectedUnlock.selector);
        router.unlockCallback(abi.encode(true, 1 ether, uint160(0)));
        assertEq(snapshotAccounting(), beforeState);
    }

    function test_WrongPoolRejectedInBothSwapCallbacks() public {
        seedPool();
        PoolKey memory wrong = key;
        wrong.tickSpacing++;
        SwapParams memory params = SwapParams(true, -1 ether, 1 << 95);
        bytes32 beforeState = snapshotAccounting();
        vm.prank(address(manager));
        vm.expectRevert(HashFrogHook.WrongPool.selector);
        hook.beforeSwap(bob, wrong, params, "");
        vm.prank(address(manager));
        vm.expectRevert(HashFrogHook.WrongPool.selector);
        hook.afterSwap(bob, wrong, params, BalanceDelta.wrap(0), "");
        assertEq(snapshotAccounting(), beforeState);
    }

    function test_RouterAndHookRejectIntegerBoundariesBeforeAccruing() public {
        bytes32 beforeState = snapshotAccounting();
        uint256[3] memory amounts = [uint256(0), uint256(uint128(type(int128).max)) + 1, type(uint256).max];
        for (uint256 j; j < amounts.length; ++j) {
            vm.expectRevert(FrogRouter.InvalidAmount.selector);
            router.quote(true, amounts[j], 0);
            vm.expectRevert(FrogRouter.InvalidAmount.selector);
            router.swap(true, amounts[j], 1, 0, vm.getBlockTimestamp());
        }
        int256[4] memory signedAmounts =
            [int256(0), type(int256).min, type(int256).max, int256(uint256(uint128(type(int128).max)) + 1)];
        for (uint256 j; j < signedAmounts.length; ++j) {
            vm.prank(address(manager));
            vm.expectRevert(HashFrogHook.InvalidSwapAmount.selector);
            hook.beforeSwap(bob, key, SwapParams(true, signedAmounts[j], 1 << 95), "");
        }
        assertEq(snapshotAccounting(), beforeState);
    }

    function test_FailedStakeCannotCreateActivePrincipalOrRewards() public {
        seedPool();
        trade(true, true, 100 ether);
        token.transfer(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientAllowance(address,uint256,uint256)", address(staking), 0, 1 ether)
        );
        staking.stake(1 ether);
        (uint256 active, uint256 exiting,, uint256 paid, uint256 credit) = staking.positions(alice);
        assertEq(active + exiting + paid + credit, 0);
        assertEq(staking.totalStaked(), 0);
        assertEq(staking.queuedRewards(), 0.9 ether);
        assertEq(token.balanceOf(address(staking)), 0);
        vm.prank(alice);
        token.approve(address(staking), 1 ether);
        vm.prank(alice);
        staking.stake(1 ether);
        vm.prank(alice);
        assertEq(staking.claim(), 0.9 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ClaimFrequencyPreservesFractionalEntitlement(uint96 a, uint96 b, uint96 input) public {
        seedPool();
        uint256 sa = bound(uint256(a), 1, 1_000_000 ether);
        uint256 sb = bound(uint256(b), 1, 1_000_000 ether);
        uint256 amount = bound(uint256(input), 100, 100 ether);
        token.transfer(alice, sa);
        token.transfer(bob, sb);
        vm.startPrank(alice);
        token.approve(address(staking), sa);
        staking.stake(sa);
        vm.stopPrank();
        vm.startPrank(bob);
        token.approve(address(staking), sb);
        staking.stake(sb);
        vm.stopPrank();
        uint256 checkpoint = vm.snapshotState();
        for (uint256 j; j < 5; ++j) {
            trade(true, true, amount);
            vm.prank(alice);
            staking.claim();
            vm.prank(bob);
            staking.claim();
        }
        uint256 aliceFrequent = imd.balanceOf(alice);
        uint256 bobFrequent = imd.balanceOf(bob);
        assertTrue(vm.revertToState(checkpoint));
        for (uint256 j; j < 5; ++j) {
            trade(true, true, amount);
        }
        vm.prank(alice);
        staking.claim();
        vm.prank(bob);
        staking.claim();
        assertEq(imd.balanceOf(alice), aliceFrequent, "claiming often must not lose fractions");
        assertEq(imd.balanceOf(bob), bobFrequent);
        assertEq(staking.totalClaimed(), aliceFrequent + bobFrequent);
        assertLe(hook.totalToStakers() - staking.totalClaimed(), 2);
        assertEq(staking.totalClaimed() + imd.balanceOf(address(staking)), hook.totalToStakers());
    }
}
