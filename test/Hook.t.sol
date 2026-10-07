// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {MockERC20} from "./mocks/MockERC20.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {HashFrogHook} from "../src/HashFrogHook.sol";
import {ClaimReceiver} from "../src/ClaimReceiver.sol";
import {FrogRouter} from "../src/FrogRouter.sol";
import {FrogOracle} from "../src/FrogOracle.sol";
import {HashFrog} from "../src/HashFrog.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract HookTest is Fixture {
    function testTokenAndPermissionsAndImmutableRuntime() public {
        assertEq(token.name(), "HFROG");
        assertEq(token.symbol(), "HFROG");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        token.transfer(alice, 123);
        assertEq(token.balanceOf(alice), 123);
        assertEq(token.balanceOf(address(this)), 1e27 - 123);
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.beforeInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta
        );
        assertFalse(
            p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity || p.afterRemoveLiquidity
                || p.beforeDonate || p.afterDonate || p.afterInitialize || p.afterAddLiquidityReturnDelta
                || p.afterRemoveLiquidityReturnDelta
        );
        assertEq(uint160(address(hook)) & 0x3fff, hook.FLAGS());
        assertTrue(hook.initialized());
        assertNoEscape(address(token));
        assertNoEscape(address(hook));
        assertNoEscape(address(frog));
        assertNoEscape(address(staking));
        assertNoEscape(address(router));
    }

    function testUnauthorizedCallbacksAndWrongPool() public {
        SwapParams memory params = SwapParams(true, -1 ether, 1 << 95);
        vm.expectRevert(ClaimReceiver.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, 1 << 96);
        vm.expectRevert(ClaimReceiver.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(ClaimReceiver.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(ClaimReceiver.OnlyPoolManager.selector);
        hook.unlockCallback(abi.encode(1));
        vm.expectRevert(FrogRouter.OnlyPoolManager.selector);
        router.unlockCallback("");
        vm.prank(address(manager));
        vm.expectRevert(ClaimReceiver.UnexpectedUnlock.selector);
        hook.unlockCallback(abi.encode(1));
        PoolKey memory wrong = key;
        wrong.fee = 3000;
        vm.prank(address(manager));
        vm.expectRevert(HashFrogHook.WrongPool.selector);
        hook.beforeInitialize(address(this), wrong, 1 << 96);
        vm.prank(address(manager));
        vm.expectRevert(HashFrogHook.AlreadyInitialized.selector);
        hook.beforeInitialize(address(this), key, 1 << 96);
    }

    function testAllFourSwapModesFeeSplitAndRedemption() public {
        seedPool();
        uint256 before = imd.balanceOf(address(this));
        BalanceDelta buy = trade(true, true, 100 ether);
        assertEq(-int256(imdDelta(buy)), 100 ether);
        assertEq(before - imd.balanceOf(address(this)), 100 ether);
        assertEq(hook.totalFees(), 1.5 ether);
        uint256 oldFees = hook.totalFees();
        BalanceDelta sell = trade(false, true, 100 ether);
        uint256 net = uint256(uint128(imdDelta(sell)));
        uint256 sellFee = hook.totalFees() - oldFees;
        assertEq(sellFee, (net + sellFee) * 150 / 10000);
        oldFees = hook.totalFees();
        BalanceDelta exactBuy = trade(true, false, 10 ether);
        uint256 input = uint256(-int256(imdDelta(exactBuy)));
        uint256 buyFee = hook.totalFees() - oldFees;
        assertEq(buyFee, (input - buyFee) * 150 / 10000);
        oldFees = hook.totalFees();
        BalanceDelta exactSell = trade(false, false, 10 ether);
        assertEq(int256(imdDelta(exactSell)), 10 ether);
        assertEq(hook.totalFees() - oldFees, uint256(10 ether) * 150 / 9850);
        assertEq(hook.totalFees(), hook.totalToStakers() + hook.totalToVault() + hook.totalToTeam());
        assertEq(staking.pendingFees(), hook.totalToStakers());
        assertEq(frog.pendingFees(), hook.totalToVault());
        assertEq(hook.pendingFees(), hook.totalToTeam());
        uint256 teamBefore = imd.balanceOf(hook.TEAM());
        vm.prank(bob);
        hook.redeemFees();
        frog.redeemFees();
        staking.redeemFees();
        assertEq(imd.balanceOf(hook.TEAM()) - teamBefore, hook.totalToTeam());
        assertEq(imd.balanceOf(address(frog)), hook.totalToVault());
        assertEq(imd.balanceOf(address(staking)), hook.totalToStakers());
        assertEq(imd.balanceOf(bob), 0);
        assertEq(hook.pendingFees() + frog.pendingFees() + staking.pendingFees(), 0);
        assertEq(hook.redeemFees(), 0);
    }

    function testFreshManagerTokenOnlyPoolBuy() public {
        bool imd0 = address(imd) < address(token);
        liquidity.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                imd0 ? int24(-6000) : int24(60), imd0 ? int24(-60) : int24(6000), 1_000_000 ether, bytes32(0)
            ),
            ""
        );
        assertEq(imd.balanceOf(address(manager)), 0, "IMD must not be pre-funded");
        (uint256 spent, uint256 bought) = router.swap(true, 10 ether, 1, 0, vm.getBlockTimestamp());
        assertEq(spent, 10 ether);
        assertGt(bought, 0);
        assertEq(hook.totalFees(), 0.15 ether);
        frog.redeemFees();
        assertEq(imd.balanceOf(address(frog)), 0.0375 ether);
    }

    function testQuoteHasNoSideEffectsAndRouterBounds() public {
        seedPool();
        uint256 before = imd.balanceOf(address(this));
        vm.prank(address(0));
        (uint256 spent, uint256 bought) = router.quote(true, 100 ether, 0);
        assertEq(hook.totalFees(), 0);
        assertEq(imd.balanceOf(address(this)), before);
        assertEq(staking.totalRewards(), 0);
        (uint256 actualSpent, uint256 actualBought) = router.swap(true, 100 ether, bought, 0, vm.getBlockTimestamp());
        assertEq(actualSpent, spent);
        assertEq(actualBought, bought);
        vm.expectRevert(FrogRouter.Slippage.selector);
        router.swap(true, 100 ether, type(uint128).max, 0, vm.getBlockTimestamp());
        vm.expectRevert(FrogRouter.Expired.selector);
        router.swap(true, 100 ether, 1, 0, vm.getBlockTimestamp() - 1);
        vm.expectRevert(FrogRouter.Slippage.selector);
        router.swap(false, 100 ether, 0, 0, vm.getBlockTimestamp());
        vm.expectRevert(FrogRouter.InvalidAmount.selector);
        router.swap(true, 0, 1, 0, vm.getBlockTimestamp());
        // A price limit that allows a tiny partial buy must not charge a full-order fee.
        uint160 limit = TickMath.getSqrtPriceAtTick(address(imd) < address(token) ? int24(-10) : int24(10));
        uint256 fees = hook.totalFees();
        vm.expectRevert();
        router.swap(true, 1_000_000 ether, 1, limit, vm.getBlockTimestamp());
        assertEq(hook.totalFees(), fees);
    }

    function testBuybackLimitsAndProtocolSlippage() public {
        seedPool();
        imd.transfer(address(frog), 1000 ether);
        vm.expectRevert(FrogOracle.OracleNotReady.selector);
        frog.buyback(100 ether, 95 ether, 0, vm.getBlockTimestamp());
        vm.warp(vm.getBlockTimestamp() + 1800);
        assertEq(hook.consult(), 0);
        vm.expectRevert(HashFrog.InvalidBuybackAmount.selector);
        frog.buyback(101 ether, 95 ether, 0, vm.getBlockTimestamp());
        vm.expectRevert(HashFrog.BuybackSlippage.selector);
        frog.buyback(100 ether, 1, 0, vm.getBlockTimestamp());
        uint256 bought = frog.buyback(100 ether, 95 ether, 0, vm.getBlockTimestamp());
        assertGt(bought, 95 ether);
        assertEq(token.balanceOf(address(frog)), bought);
        assertEq(imd.balanceOf(address(frog)), 900 ether);
        assertEq(imd.allowance(address(frog), address(router)), 0);
        vm.expectRevert(abi.encodeWithSelector(HashFrog.BuybackCooldown.selector, vm.getBlockTimestamp() + 60));
        frog.buyback(100 ether, 95 ether, 0, vm.getBlockTimestamp());
        vm.warp(vm.getBlockTimestamp() + 59);
        vm.expectRevert();
        frog.buyback(100 ether, 95 ether, 0, vm.getBlockTimestamp());
        vm.warp(vm.getBlockTimestamp() + 1);
        frog.buyback(100 ether, 95 ether, 0, vm.getBlockTimestamp());
        assertEq(frog.totalBuybackIMD(), 200 ether);
        assertEq(hook.totalFees(), 3 ether, "buybacks also pay the hook fee");
    }

    function testBuybackRejectsManipulatedSpotAndRollsBackCooldown() public {
        seedPool();
        imd.transfer(address(frog), 100 ether);
        vm.warp(vm.getBlockTimestamp() + 1800);
        trade(true, true, 10_000_000 ether);
        assertEq(hook.consult(), 0, "same-block price change has no TWAP weight");
        uint256 before = frog.lastBuyback();
        vm.expectRevert();
        frog.buyback(100 ether, 95 ether, 0, vm.getBlockTimestamp());
        assertEq(frog.lastBuyback(), before);
        assertEq(token.balanceOf(address(frog)), 0);
        assertEq(imd.balanceOf(address(frog)), 100 ether);
    }

    function testFuzzBuyFeeAndConservation(uint96 raw) public {
        uint256 amount = bound(uint256(raw), 1e8, 10000 ether);
        seedPool();
        uint256 before = imd.balanceOf(address(this));
        router.swap(true, amount, 1, 0, vm.getBlockTimestamp());
        uint256 fee = amount * 150 / 10000;
        assertEq(before - imd.balanceOf(address(this)), amount);
        assertEq(hook.totalFees(), fee);
        assertEq(staking.pendingFees(), fee * 60 / 100);
        assertEq(frog.pendingFees(), fee * 25 / 100);
        assertEq(hook.pendingFees(), fee - fee * 60 / 100 - fee * 25 / 100);
    }
}

contract IMDIsCurrency0Test is HookTest {
    function deployAssets() internal override {
        super.deployAssets();
        while (address(imd) > address(token)) imd = new MockERC20("IdentityMD", "IMD", 1e30);
    }
}

contract IMDIsCurrency1Test is HookTest {
    function deployAssets() internal override {
        super.deployAssets();
        while (address(imd) < address(token)) imd = new MockERC20("IdentityMD", "IMD", 1e30);
    }
}
