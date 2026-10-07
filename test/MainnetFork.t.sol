// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MainnetRehearsal} from "../script/MainnetRehearsal.s.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Makes the existing real-manager rehearsal discoverable by forge test.
/// No RPC or unverified mainnet contract address is embedded in the offline suite.
contract MainnetForkTest is MainnetRehearsal {
    function test_MainnetBuySellClaimBurnAndHackathonAcceptance() public {
        string memory rpc = vm.envOr("HASHFROG_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        // A configured run must supply all authoritative launch inputs. Missing or
        // invalid inputs fail visibly; they never turn into a passing empty test.
        uint256 atBlock = vm.envUint("HASHFROG_FORK_BLOCK");
        address manager = vm.envAddress("HASHFROG_FORK_POOL_MANAGER");
        address pair = vm.envAddress("HASHFROG_FORK_IMD");
        require(atBlock != 0 && manager != address(0) && pair != address(0), "explicit mainnet inputs required");
        this.run(rpc, atBlock, IPoolManager(manager), IERC20(pair));
    }
}
