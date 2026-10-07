// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ClaimReceiver} from "./ClaimReceiver.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract FrogStaking is ClaimReceiver {
    using SafeERC20 for IERC20;

    uint256 public constant PRECISION = 1e36;
    uint256 public constant UNSTAKE_DELAY = 24 hours;
    IERC20 public immutable hfrog;
    address public immutable hook;
    uint256 public totalStaked;
    uint256 public rewardPerToken;
    uint256 public queuedRewards;
    uint256 public scaledRemainder;
    uint256 public totalRewards;
    uint256 public totalClaimed;

    struct Position {
        uint256 active;
        uint256 exiting;
        uint256 unlockAt;
        uint256 paidAccumulator;
        uint256 creditScaled;
    }
    mapping(address => Position) public positions;

    error OnlyHook();
    error InvalidAmount();
    error TooEarly(uint256 unlockAt);
    error UnsupportedToken();
    event Staked(address indexed account, uint256 amount);
    event ExitRequested(address indexed account, uint256 amount, uint256 unlockAt);
    event Unstaked(address indexed account, uint256 amount);
    event RewardAdded(uint256 amount);
    event Claimed(address indexed account, uint256 amount);

    constructor(IPoolManager manager_, IERC20 token_, IERC20 imd_, address hook_)
        ClaimReceiver(manager_, imd_, address(0))
    {
        hfrog = token_;
        hook = hook_;
    }

    /// @dev Called immediately after the hook mints this contract's ERC-6909 claims.
    /// Rewards accrue at swap time, not when someone chooses to redeem the claims.
    function notifyReward(uint256 amount) external {
        if (msg.sender != hook) revert OnlyHook();
        totalRewards += amount;
        _allocate(amount);
        emit RewardAdded(amount);
    }

    function _allocate(uint256 amount) private {
        if (totalStaked == 0) {
            queuedRewards += amount;
        } else {
            uint256 scaled = (amount + queuedRewards) * PRECISION + scaledRemainder;
            queuedRewards = 0;
            rewardPerToken += scaled / totalStaked;
            scaledRemainder = scaled % totalStaked;
        }
    }

    function _checkpoint(Position storage p) private {
        p.creditScaled += p.active * (rewardPerToken - p.paidAccumulator);
        p.paidAccumulator = rewardPerToken;
    }

    function earned(address account) public view returns (uint256) {
        Position storage p = positions[account];
        return (p.creditScaled + p.active * (rewardPerToken - p.paidAccumulator)) / PRECISION;
    }

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        Position storage p = positions[msg.sender];
        _checkpoint(p);
        p.active += amount;
        totalStaked += amount;
        uint256 beforeBalance = hfrog.balanceOf(address(this));
        hfrog.safeTransferFrom(msg.sender, address(this), amount);
        if (hfrog.balanceOf(address(this)) - beforeBalance != amount) revert UnsupportedToken();
        _allocate(0);
        emit Staked(msg.sender, amount);
    }

    function requestUnstake(uint256 amount) external nonReentrant {
        Position storage p = positions[msg.sender];
        if (amount == 0 || amount > p.active) revert InvalidAmount();
        _checkpoint(p);
        p.active -= amount;
        totalStaked -= amount;
        p.exiting += amount;
        p.unlockAt = block.timestamp + UNSTAKE_DELAY;
        emit ExitRequested(msg.sender, amount, p.unlockAt);
    }

    function unstake() external nonReentrant returns (uint256 amount) {
        Position storage p = positions[msg.sender];
        if (p.exiting == 0) revert InvalidAmount();
        if (block.timestamp < p.unlockAt) revert TooEarly(p.unlockAt);
        amount = p.exiting;
        p.exiting = 0;
        p.unlockAt = 0;
        hfrog.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claim() external nonReentrant returns (uint256 amount) {
        Position storage p = positions[msg.sender];
        _checkpoint(p);
        amount = p.creditScaled / PRECISION;
        p.creditScaled %= PRECISION;
        totalClaimed += amount;
        _redeemFees();
        if (amount != 0) imd.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }
}
