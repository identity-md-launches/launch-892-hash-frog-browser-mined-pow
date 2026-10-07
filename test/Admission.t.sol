// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Fixture} from "./helpers/Fixture.sol";
import {HashFrogHook} from "../src/HashFrogHook.sol";
import {ClaimReceiver} from "../src/ClaimReceiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

contract AdmissionTest is Fixture {
    function testConstructorProbeAndMissingPairInitialization() public {
        IERC20 externalPair = IERC20(address(0x123456));
        bytes memory code =
            abi.encodePacked(type(HashFrogHook).creationCode, abi.encode(manager, token, externalPair, int24(60)));
        bytes32 hash = keccak256(code);
        address at;
        for (uint256 i; i < 200000; i++) {
            address candidate =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), hash)))));
            if (uint160(candidate) & 0x3fff != 0x20cc) continue;
            bytes32 salt = bytes32(i);
            assembly ("memory-safe") { at := create2(0, add(code, 32), mload(code), salt) }
            break;
        }
        assertGt(at.code.length, 0);
        HashFrogHook probe = HashFrogHook(at);
        assertTrue(probe.getHookPermissions().beforeInitialize);
        assertFalse(probe.initialized());
        PoolKey memory k = probe.poolKey();
        vm.expectRevert(ClaimReceiver.OnlyPoolManager.selector);
        probe.beforeInitialize(address(this), k, 1 << 96);
        vm.prank(address(manager));
        vm.expectRevert(HashFrogHook.InvalidConfiguration.selector);
        probe.beforeInitialize(address(this), k, 1 << 96);
        assertFalse(probe.initialized());
    }
}
