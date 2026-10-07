// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {HFROG} from "src/HFROG.sol";
import {HashFrog} from "src/HashFrog.sol";
import {HashFrogHook} from "src/HashFrogHook.sol";
import {FrogStaking} from "src/FrogStaking.sol";
import {FrogRouter} from "src/FrogRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract SystemSequenceHandler is Test {
    HFROG public token;
    MockERC20 public imd;
    HashFrogHook public hook;
    HashFrog public frog;
    FrogStaking public staking;
    FrogRouter public router;
    address[3] public actors = [address(0xA11CE), address(0xB0B), address(0xCAFE)];
    uint256[3] public active;
    uint256[3] public exiting;
    uint256[3] public unlockAt;
    uint256[3] public deposits;
    uint256[3] public withdrawals;
    uint256[3] public claims;
    uint256 public ghostStakerFees;
    uint256 public ghostVaultFees;
    uint256 public ghostTeamFees;
    uint256 public donatedIMD;
    uint256 public donatedHFROG;
    uint256 public buybackSpent;
    uint256 public buybackBought;
    uint256 public burnIMD;
    uint256 public burnHFROG;
    uint256 public lastBuyback;
    bool public burned;

    constructor(HashFrogHook h) {
        hook = h;
        token = HFROG(address(h.hfrog()));
        imd = MockERC20(address(h.imd()));
        frog = h.frog();
        staking = h.staking();
        router = h.router();
        token.approve(address(router), type(uint256).max);
        imd.approve(address(router), type(uint256).max);
        for (uint256 j; j < 3; ++j) {
            vm.prank(actors[j]);
            token.approve(address(staking), type(uint256).max);
        }
    }

    function accountFee(uint256 fee) private {
        uint256 a = fee * 60 / 100;
        uint256 b = fee * 25 / 100;
        ghostStakerFees += a;
        ghostVaultFees += b;
        ghostTeamFees += fee - a - b;
    }

    function swap(bool buy, uint96 raw) public {
        uint256 amount = bound(uint256(raw), 100, 100 ether);
        uint256[3] memory earnedBefore;
        for (uint256 j; j < 3; ++j) {
            earnedBefore[j] = staking.earned(actors[j]);
        }
        uint256 feesBefore = hook.totalFees();
        (uint256 spent, uint256 received) = router.swap(buy, amount, 1, 0, vm.getBlockTimestamp());
        assertEq(spent, amount);
        uint256 fee = hook.totalFees() - feesBefore;
        assertEq(fee, (buy ? spent : received + fee) * 150 / 10_000);
        accountFee(fee);
        for (uint256 j; j < 3; ++j) {
            if (active[j] == 0) {
                assertEq(staking.earned(actors[j]), earnedBefore[j], "exiting principal earns nothing");
            }
        }
    }

    function stake(uint8 who, uint96 raw) public {
        uint256 j = who % 3;
        uint256 balance = token.balanceOf(actors[j]);
        if (balance == 0) return;
        uint256 amount = bound(uint256(raw), 1, balance);
        vm.prank(actors[j]);
        staking.stake(amount);
        active[j] += amount;
        deposits[j] += amount;
    }

    function requestExit(uint8 who, uint96 raw) public {
        uint256 j = who % 3;
        if (active[j] == 0) return;
        uint256 amount = bound(uint256(raw), 1, active[j]);
        vm.prank(actors[j]);
        staking.requestUnstake(amount);
        active[j] -= amount;
        exiting[j] += amount;
        unlockAt[j] = vm.getBlockTimestamp() + 24 hours;
    }

    function unstake(uint8 who) public {
        uint256 j = who % 3;
        vm.prank(actors[j]);
        if (exiting[j] == 0) {
            vm.expectRevert(FrogStaking.InvalidAmount.selector);
            staking.unstake();
        } else if (vm.getBlockTimestamp() < unlockAt[j]) {
            vm.expectRevert(abi.encodeWithSelector(FrogStaking.TooEarly.selector, unlockAt[j]));
            staking.unstake();
        } else {
            uint256 amount = staking.unstake();
            assertEq(amount, exiting[j]);
            withdrawals[j] += amount;
            exiting[j] = 0;
            unlockAt[j] = 0;
        }
    }

    function claim(uint8 who) public {
        uint256 j = who % 3;
        uint256 balance = imd.balanceOf(actors[j]);
        uint256 expected = staking.earned(actors[j]);
        vm.prank(actors[j]);
        uint256 amount = staking.claim();
        assertEq(amount, expected);
        assertEq(imd.balanceOf(actors[j]) - balance, amount);
        claims[j] += amount;
    }

    function donate(uint96 t, uint96 i) public {
        uint256 a = bound(uint256(t), 0, 100 ether);
        uint256 b = bound(uint256(i), 0, 100 ether);
        token.transfer(address(frog), a);
        imd.transfer(address(frog), b);
        donatedHFROG += a;
        donatedIMD += b;
    }

    function buyback(uint96 raw) public {
        if (vm.getBlockTimestamp() < lastBuyback + 60) return;
        uint256 available = imd.balanceOf(address(frog)) + frog.pendingFees();
        if (available < 100) return;
        uint256 amount = bound(uint256(raw), 100, available > 100 ether ? 100 ether : available);
        uint256 floor = hook.quoteAtTick(hook.consult(), uint128(amount), address(imd) < address(token)) * 95 / 100;
        uint256 oldIMD = imd.balanceOf(address(frog)) + frog.pendingFees();
        uint256 oldToken = token.balanceOf(address(frog));
        uint256 callerIMD = imd.balanceOf(address(this));
        uint256 callerToken = token.balanceOf(address(this));
        uint256 fee = amount * 150 / 10_000;
        uint256 received = frog.buyback(amount, floor, 0, vm.getBlockTimestamp());
        assertGe(received, floor);
        assertEq(token.balanceOf(address(frog)) - oldToken, received);
        assertEq(imd.balanceOf(address(frog)) + frog.pendingFees(), oldIMD - amount + fee * 25 / 100);
        assertEq(imd.balanceOf(address(this)), callerIMD);
        assertEq(token.balanceOf(address(this)), callerToken);
        assertEq(imd.allowance(address(frog), address(router)), 0);
        accountFee(fee);
        buybackSpent += amount;
        buybackBought += received;
        lastBuyback = vm.getBlockTimestamp();
    }

    function burn() public {
        if (burned) return;
        uint256 expectedIMD = imd.balanceOf(address(frog)) + frog.pendingFees();
        uint256 expectedHFROG = token.balanceOf(address(frog));
        uint256 beforeIMD = imd.balanceOf(actors[0]);
        uint256 beforeHFROG = token.balanceOf(actors[0]);
        vm.prank(actors[0]);
        (burnHFROG, burnIMD) = frog.burn(1);
        assertEq(burnIMD, expectedIMD);
        assertEq(burnHFROG, expectedHFROG);
        assertEq(imd.balanceOf(actors[0]) - beforeIMD, burnIMD);
        assertEq(token.balanceOf(actors[0]) - beforeHFROG, burnHFROG);
        burned = true;
    }

    function redeem() public {
        hook.redeemFees();
        frog.redeemFees();
        staking.redeemFees();
    }

    function advance(uint32 raw) public {
        vm.warp(vm.getBlockTimestamp() + bound(uint256(raw), 0, 2 days));
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract SystemStatefulTest is Fixture {
    SystemSequenceHandler handler;

    function setUp() public override {
        super.setUp();
        seedPool();
        vm.setBlockhash(99, keccak256("reference"));
        vm.deal(alice, 1 ether);
        bytes32 seed = frog.lastSeed();
        vm.prank(alice);
        frog.mine{value: 0.0019 ether}(729977, seed, 99);
        vm.warp(vm.getBlockTimestamp() + 1800);
        handler = new SystemSequenceHandler(hook);
        token.transfer(address(handler), 1_000_000 ether);
        imd.transfer(address(handler), 1_000_000 ether);
        for (uint256 j; j < 3; ++j) {
            token.transfer(handler.actors(j), 10_000 ether);
        }
        // Exercise queued rewards and active/exiting positions in every run.
        handler.swap(true, 100 ether);
        handler.stake(0, 3 ether);
        handler.stake(1, 7 ether);
        handler.requestExit(1, 7 ether);
        handler.swap(false, 100 ether);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.stake.selector;
        selectors[2] = handler.requestExit.selector;
        selectors[3] = handler.unstake.selector;
        selectors[4] = handler.claim.selector;
        selectors[5] = handler.donate.selector;
        selectors[6] = handler.buyback.selector;
        selectors[7] = handler.burn.selector;
        selectors[8] = handler.redeem.selector;
        selectors[9] = handler.advance.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_FeesAreBackedAtTheirFixedDestinations() public view {
        assertEq(hook.totalFees(), handler.ghostStakerFees() + handler.ghostVaultFees() + handler.ghostTeamFees());
        assertEq(staking.totalRewards(), handler.ghostStakerFees());
        uint256 paid;
        for (uint256 j; j < 3; ++j) {
            paid += handler.claims(j);
            assertEq(imd.balanceOf(handler.actors(j)), handler.claims(j) + (j == 0 ? handler.burnIMD() : 0));
        }
        assertEq(staking.totalClaimed(), paid);
        assertEq(paid + imd.balanceOf(address(staking)) + staking.pendingFees(), handler.ghostStakerFees());
        assertEq(imd.balanceOf(hook.TEAM()) + hook.pendingFees(), handler.ghostTeamFees());
        assertEq(
            imd.balanceOf(address(frog)) + frog.pendingFees() + handler.buybackSpent() + handler.burnIMD(),
            handler.ghostVaultFees() + handler.donatedIMD()
        );
        assertEq(token.balanceOf(address(frog)) + handler.burnHFROG(), handler.buybackBought() + handler.donatedHFROG());
        assertEq(frog.totalBuybackIMD(), handler.buybackSpent());
        assertEq(frog.totalBoughtHFROG(), handler.buybackBought());
        assertEq(frog.lastBuyback(), handler.lastBuyback());
        assertEq(token.balanceOf(address(router)) + imd.balanceOf(address(router)), 0);
        assertEq(token.balanceOf(address(hook)) + imd.balanceOf(address(hook)), 0);
    }

    function invariant_StakingPrincipalAndRewardsStaySolvent() public view {
        uint256 totalActive;
        uint256 totalExiting;
        uint256 earned;
        for (uint256 j; j < 3; ++j) {
            (uint256 a, uint256 e, uint256 unlock,,) = staking.positions(handler.actors(j));
            assertEq(a, handler.active(j));
            assertEq(e, handler.exiting(j));
            assertEq(unlock, handler.unlockAt(j));
            assertEq(a + e + handler.withdrawals(j), handler.deposits(j));
            assertEq(token.balanceOf(handler.actors(j)) + a + e, 10_000 ether + (j == 0 ? handler.burnHFROG() : 0));
            totalActive += a;
            totalExiting += e;
            earned += staking.earned(handler.actors(j));
        }
        assertEq(staking.totalStaked(), totalActive);
        assertEq(token.balanceOf(address(staking)), totalActive + totalExiting);
        assertLe(earned + staking.queuedRewards(), imd.balanceOf(address(staking)) + staking.pendingFees());
    }

    function invariant_FixedSupplyCannotEscapeTrackedAccounts() public view {
        address[8] memory accounts = [
            address(this),
            address(handler),
            address(manager),
            address(frog),
            address(staking),
            address(hook),
            address(router),
            hook.TEAM()
        ];
        uint256 tokens;
        uint256 pair;
        for (uint256 j; j < accounts.length; ++j) {
            tokens += token.balanceOf(accounts[j]);
            pair += imd.balanceOf(accounts[j]);
        }
        for (uint256 j; j < 3; ++j) {
            tokens += token.balanceOf(handler.actors(j));
            pair += imd.balanceOf(handler.actors(j));
        }
        assertEq(tokens, 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertEq(pair, imd.totalSupply());
    }

    function afterInvariant() public {
        for (uint8 j; j < 3; ++j) {
            handler.requestExit(j, uint96(handler.active(j)));
        }
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        for (uint8 j; j < 3; ++j) {
            handler.unstake(j);
            handler.claim(j);
            assertEq(handler.withdrawals(j), handler.deposits(j), "principal must remain withdrawable");
        }
        handler.burn();
        handler.redeem();
        assertEq(token.balanceOf(address(staking)), 0);
        assertLe(imd.balanceOf(address(staking)), staking.queuedRewards() + 3, "only fractional reward dust remains");
        invariant_FeesAreBackedAtTheirFixedDestinations();
        invariant_StakingPrincipalAndRewardsStaySolvent();
        invariant_FixedSupplyCannotEscapeTrackedAccounts();
    }
}
