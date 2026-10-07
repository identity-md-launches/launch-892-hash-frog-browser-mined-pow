// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Exact-input router for this one immutable pool. Pays output only to the payer.
contract FrogRouter is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    IPoolManager public immutable poolManager;
    IERC20 public immutable hfrog;
    IERC20 public immutable imd;
    address public immutable hook;
    int24 public immutable tickSpacing;
    address private payer;
    bool private quoting;

    error InvalidAmount();
    error Expired();
    error Slippage();
    error OnlyPoolManager();
    error UnexpectedUnlock();
    error QuoteResult(uint256 spent, uint256 received);
    error UnexpectedQuoteSuccess();
    event Swapped(address indexed account, bool buy, uint256 spent, uint256 received);

    constructor(IPoolManager manager_, IERC20 hfrog_, IERC20 imd_, address hook_, int24 spacing_) {
        poolManager = manager_;
        hfrog = hfrog_;
        imd = imd_;
        hook = hook_;
        tickSpacing = spacing_;
    }

    function poolKey() public view returns (PoolKey memory) {
        (address a, address b) =
            address(imd) < address(hfrog) ? (address(imd), address(hfrog)) : (address(hfrog), address(imd));
        return PoolKey(Currency.wrap(a), Currency.wrap(b), 12500, tickSpacing, IHooks(hook));
    }

    function swap(bool buy, uint256 amountIn, uint256 minOut, uint160 priceLimit, uint256 deadline)
        external
        nonReentrant
        returns (uint256 spent, uint256 received)
    {
        if (block.timestamp > deadline) revert Expired();
        if (minOut == 0) revert Slippage();
        _checkAmount(amountIn);
        payer = msg.sender;
        (spent, received) = abi.decode(poolManager.unlock(abi.encode(buy, amountIn, priceLimit)), (uint256, uint256));
        payer = address(0);
        if (received < minOut) revert Slippage();
        emit Swapped(msg.sender, buy, spent, received);
    }

    /// @notice Call with eth_call. The swap and its hook effects are always reverted internally.
    function quote(bool buy, uint256 amountIn, uint160 priceLimit)
        external
        nonReentrant
        returns (uint256 spent, uint256 received)
    {
        _checkAmount(amountIn);
        payer = address(this); // Quotes never transfer; eth_call may use the zero address.
        quoting = true;
        try poolManager.unlock(abi.encode(buy, amountIn, priceLimit)) {
            revert UnexpectedQuoteSuccess();
        } catch (bytes memory reason) {
            payer = address(0);
            quoting = false;
            if (reason.length != 68 || bytes4(reason) != QuoteResult.selector) {
                assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
            }
            assembly ("memory-safe") {
                spent := mload(add(reason, 36))
                received := mload(add(reason, 68))
            }
        }
    }

    function _checkAmount(uint256 amount) private pure {
        if (amount == 0 || amount > uint256(uint128(type(int128).max))) revert InvalidAmount();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        if (payer == address(0)) revert UnexpectedUnlock();
        (bool buy, uint256 amount, uint160 limit) = abi.decode(data, (bool, uint256, uint160));
        bool zeroForOne = buy == (address(imd) < address(hfrog));
        if (limit == 0) limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta delta = poolManager.swap(poolKey(), SwapParams(zeroForOne, -int256(amount), limit), "");
        int128 input = zeroForOne ? delta.amount0() : delta.amount1();
        int128 output = zeroForOne ? delta.amount1() : delta.amount0();
        if (input >= 0 || output <= 0) revert Slippage();
        uint256 spent = uint256(-int256(input));
        uint256 received = uint256(uint128(output));
        if (spent > amount) revert Slippage();
        if (quoting) revert QuoteResult(spent, received);
        IERC20 tokenIn = buy ? imd : hfrog;
        IERC20 tokenOut = buy ? hfrog : imd;
        poolManager.sync(Currency.wrap(address(tokenIn)));
        tokenIn.safeTransferFrom(payer, address(poolManager), spent);
        poolManager.settle();
        poolManager.take(Currency.wrap(address(tokenOut)), payer, received);
        return abi.encode(spent, received);
    }
}
