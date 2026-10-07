// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {HFROG} from "../src/HFROG.sol";
import {HashFrogHook} from "../src/HashFrogHook.sol";
import {HashFrog} from "../src/HashFrog.sol";
import {FrogRouter} from "../src/FrogRouter.sol";
import {FrogStaking} from "../src/FrogStaking.sol";

/// @notice Explicit-argument, read-only mainnet rehearsal; never broadcasts or uses environment variables.
/// Requires a real IMD address and a real PoolManager supplied by the launch coordinator.
contract MainnetRehearsal is Test {
    using stdStorage for StdStorage;

    function run(string calldata rpc, uint256 forkBlock, IPoolManager manager, IERC20 pair) external {
        vm.createSelectFork(rpc, forkBlock);
        require(
            block.chainid == 1 && address(manager).code.length > 0 && address(pair).code.length > 0,
            "mainnet inputs required"
        );
        require(IERC20Metadata(address(pair)).decimals() == 18, "18-decimal IMD required");
        require(
            keccak256(bytes(IERC20Metadata(address(pair)).symbol())) == keccak256("IMD"), "pair must identify as IMD"
        );
        HFROG token = new HFROG();
        bytes memory code =
            abi.encodePacked(type(HashFrogHook).creationCode, abi.encode(manager, token, pair, int24(60)));
        bytes32 hash = keccak256(code);
        address at;
        for (uint256 i; i < 200000; i++) {
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), hash)))));
            if (uint160(predicted) & 0x3fff != 0x20cc) continue;
            bytes32 salt = bytes32(i);
            assembly ("memory-safe") { at := create2(0, add(code, 32), mload(code), salt) }
            break;
        }
        require(at.code.length > 0, "hook deployment failed");
        HashFrogHook hook = HashFrogHook(at);
        manager.initialize(hook.poolKey(), 1 << 96);
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        deal(address(pair), address(this), 100_000_000 ether);
        token.approve(address(lp), 10_000_000 ether);
        pair.approve(address(lp), 10_000_000 ether);
        lp.modifyLiquidity(hook.poolKey(), ModifyLiquidityParams(-60000, 60000, 10_000_000 ether, bytes32(0)), "");
        FrogRouter router = hook.router();
        FrogStaking staking = hook.staking();
        HashFrog frog = hook.frog();
        pair.approve(address(router), 100 ether);
        (uint256 spent, uint256 got) = router.swap(true, 100 ether, 1, 0, vm.getBlockTimestamp());
        assertEq(spent, 100 ether);
        assertGt(got, 0);
        token.approve(address(staking), got);
        staking.stake(got);
        token.approve(address(router), 10 ether);
        router.swap(false, 10 ether, 1, 0, vm.getBlockTimestamp());
        staking.claim();
        assertApproxEqAbs(staking.totalClaimed(), hook.totalToStakers(), 1);
        // Only NFT PoW difficulty is relaxed for this integration check. Unit/browser tests verify real PoW.
        stdstore.target(address(frog)).sig("target()").checked_write(type(uint256).max);
        address miner = address(0xA11CE);
        vm.deal(miner, 1 ether);
        address hack = frog.HACKATHON();
        require(hack.code.length > 0, "hackathon recipient must be the live contract");
        uint256 creditBefore = frog.ethCredit(hack);
        uint256 forwardedBefore = frog.ethToHackathon();
        bytes32 seed = frog.lastSeed();
        uint256 refBlock = block.number - 1;
        vm.prank(miner);
        frog.mine{value: 0.0019 ether}(0, seed, refBlock);
        assertEq(frog.ethCredit(hack), creditBefore, "live hackathon contract rejected ETH");
        assertEq(frog.ethToHackathon() - forwardedBefore, 0.001615 ether);
        hook.redeemFees();
        frog.redeemFees();
        vm.prank(miner);
        frog.burn(1);
        assertEq(pair.balanceOf(address(frog)), 0);
        console2.log("Mainnet rehearsal passed at block", forkBlock);
        console2.log("PoolManager", address(manager));
        console2.log("IMD", address(pair));
        console2.log("Simulated hook", address(hook));
    }
}
