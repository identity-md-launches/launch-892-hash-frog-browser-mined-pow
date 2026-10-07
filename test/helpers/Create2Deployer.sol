// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Local integration helper. Not a launch factory or a production companion.
contract Create2Deployer {
    function deploy(bytes32 salt, bytes memory code) external returns (address at) {
        assembly ("memory-safe") { at := create2(0, add(code, 32), mload(code), salt) }
        require(at != address(0), "create2 failed");
    }
}
