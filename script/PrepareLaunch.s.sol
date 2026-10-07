// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {HashFrogHook} from "../src/HashFrogHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Pure launch preparation; does not broadcast, read secrets, or assume a caller.
contract PrepareLaunch {
    function creationCode(IPoolManager manager, IERC20 token, IERC20 pair, int24 tickSpacing)
        public
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(type(HashFrogHook).creationCode, abi.encode(manager, token, pair, tickSpacing));
    }

    function findSalt(address factory, bytes32 initCodeHash, uint256 start, uint256 attempts)
        public
        pure
        returns (bytes32 salt, address predicted)
    {
        require(factory != address(0) && attempts <= 1_000_000, "invalid search");
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(start + i);
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, initCodeHash)))));
            if (uint160(predicted) & 0x3fff == 0x20cc) return (salt, predicted);
        }
        revert("search next range");
    }
}
