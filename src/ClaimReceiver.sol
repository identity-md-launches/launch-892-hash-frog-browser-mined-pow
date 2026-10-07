// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Claims let swaps collect fees even before the router has settled its input.
/// Redemption has a fixed destination, is permissionless, and never accepts user-supplied calls.
abstract contract ClaimReceiver is IUnlockCallback, ReentrancyGuard {
    IPoolManager public immutable poolManager;
    IERC20 public immutable imd;
    address public immutable redemptionRecipient;
    uint256 public totalRedeemed;
    bool private redeeming;

    error OnlyPoolManager();
    error UnexpectedUnlock();
    event FeesRedeemed(address indexed recipient, uint256 amount);

    constructor(IPoolManager manager_, IERC20 imd_, address recipient_) {
        poolManager = manager_;
        imd = imd_;
        redemptionRecipient = recipient_ == address(0) ? address(this) : recipient_;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function pendingFees() public view returns (uint256) {
        return poolManager.balanceOf(address(this), uint256(uint160(address(imd))));
    }

    function redeemFees() external nonReentrant returns (uint256) {
        return _redeemFees();
    }

    function _redeemFees() internal returns (uint256 amount) {
        amount = pendingFees();
        if (amount == 0) return 0;
        redeeming = true;
        poolManager.unlock(abi.encode(amount));
        redeeming = false;
        totalRedeemed += amount;
        emit FeesRedeemed(redemptionRecipient, amount);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (!redeeming) revert UnexpectedUnlock();
        redeeming = false;
        uint256 amount = abi.decode(data, (uint256));
        poolManager.burn(address(this), uint256(uint160(address(imd))), amount);
        poolManager.take(Currency.wrap(address(imd)), redemptionRecipient, amount);
        return "";
    }
}
