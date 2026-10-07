// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HFROG} from "../../src/HFROG.sol";
import {HashFrogHook} from "../../src/HashFrogHook.sol";
import {HashFrog} from "../../src/HashFrog.sol";
import {FrogRouter} from "../../src/FrogRouter.sol";
import {FrogStaking} from "../../src/FrogStaking.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

abstract contract Fixture is Test {
    HFROG internal token;
    MockERC20 internal imd;
    PoolManager internal manager;
    HashFrogHook internal hook;
    HashFrog internal frog;
    FrogRouter internal router;
    FrogStaking internal staking;
    PoolSwapTest internal swaps;
    PoolModifyLiquidityTest internal liquidity;
    PoolKey internal key;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public virtual {
        vm.warp(1_000_000);
        vm.roll(100);
        manager = new PoolManager(address(this));
        deployAssets();
        bytes memory creation =
            abi.encodePacked(type(HashFrogHook).creationCode, abi.encode(manager, token, imd, int24(60)));
        bytes32 hash = keccak256(creation);
        address at;
        for (uint256 i; i < 200_000; ++i) {
            at = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), hash)))));
            if (uint160(at) & 0x3fff != 0x20cc) continue;
            bytes32 salt = bytes32(i);
            assembly ("memory-safe") { at := create2(0, add(creation, 32), mload(creation), salt) }
            require(at != address(0), "deploy failed");
            break;
        }
        require(at.code.length > 0, "no salt");
        hook = HashFrogHook(at);
        frog = hook.frog();
        router = hook.router();
        staking = hook.staking();
        key = hook.poolKey();
        manager.initialize(key, 1 << 96);
        swaps = new PoolSwapTest(manager);
        liquidity = new PoolModifyLiquidityTest(manager);
        token.approve(address(liquidity), type(uint256).max);
        imd.approve(address(liquidity), type(uint256).max);
        token.approve(address(swaps), type(uint256).max);
        imd.approve(address(swaps), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        imd.approve(address(router), type(uint256).max);
        token.approve(address(staking), type(uint256).max);
    }

    function deployAssets() internal virtual {
        token = new HFROG();
        imd = new MockERC20("IdentityMD", "IMD", 1e30);
    }

    function seedPool() internal {
        liquidity.modifyLiquidity(key, ModifyLiquidityParams(-60000, 60000, 10_000_000 ether, bytes32(0)), "");
    }

    function trade(bool buy, bool exactInput, uint256 amount) internal returns (BalanceDelta) {
        bool zeroForOne = buy == (address(imd) < address(token));
        return swaps.swap(
            key,
            SwapParams(
                zeroForOne,
                exactInput ? -int256(amount) : int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function imdDelta(BalanceDelta d) internal view returns (int128) {
        return address(imd) < address(token) ? d.amount0() : d.amount1();
    }

    function assertNoEscape(address target) internal view {
        bytes memory code = target.code;
        assertLe(code.length, 24576);
        for (uint256 i; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xff && op != 0xf2, "escape opcode");
        }
    }
}
