// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice The launch factory receives the entire fixed supply. No privileged methods.
contract HFROG is ERC20 {
    constructor() ERC20("HFROG", "HFROG") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
