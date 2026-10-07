// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ClaimReceiver} from "./ClaimReceiver.sol";
import {FrogOracle} from "./FrogOracle.sol";
import {FrogStaking} from "./FrogStaking.sol";
import {FrogRouter} from "./FrogRouter.sol";
import {HashFrog} from "./HashFrog.sol";

/// @notice Immutable IMD-denominated swap fees. The constructor atomically deploys all companions.
contract HashFrogHook is ClaimReceiver, FrogOracle {
    using StateLibrary for IPoolManager;
    uint160 public constant FLAGS = 0x20cc;
    uint256 public constant FEE_BPS = 150;
    address public constant TEAM = 0x789C9aDDa69a5880fe70eb4FBC8147F2a54B6363;
    IERC20 public immutable hfrog;
    FrogStaking public immutable staking;
    FrogRouter public immutable router;
    HashFrog public immutable frog;
    int24 public immutable tickSpacing;
    bool public initialized;
    uint256 public totalFees;
    uint256 public totalToStakers;
    uint256 public totalToVault;
    uint256 public totalToTeam;

    error InvalidConfiguration();
    error WrongPool();
    error AlreadyInitialized();
    error NotInitialized();
    error InvalidSwapAmount();
    error PartialFillUnsupported();
    error NoSwap();
    event PoolBound(bytes32 indexed poolId);
    event FeeAccrued(uint256 amount, uint256 stakers, uint256 vault, uint256 team);

    constructor(IPoolManager manager_, IERC20 token_, IERC20 imd_, int24 spacing_) ClaimReceiver(manager_, imd_, TEAM) {
        if (
            address(manager_).code.length == 0 || address(token_).code.length == 0 || address(imd_) == address(0)
                || token_ == imd_ || spacing_ < 1 || spacing_ > 32767
                || IERC20Metadata(address(token_)).decimals() != 18
        ) {
            revert InvalidConfiguration();
        }
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        hfrog = token_;
        tickSpacing = spacing_;
        staking = new FrogStaking(manager_, token_, imd_, address(this));
        router = new FrogRouter(manager_, token_, imd_, address(this), spacing_);
        frog = new HashFrog(manager_, token_, imd_, router, address(this));
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function poolKey() public view returns (PoolKey memory) {
        (address a, address b) =
            address(imd) < address(hfrog) ? (address(imd), address(hfrog)) : (address(hfrog), address(imd));
        return PoolKey(Currency.wrap(a), Currency.wrap(b), 12500, tickSpacing, IHooks(address(this)));
    }

    function _checkPool(PoolKey calldata key) private view {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolKey().toId())) revert WrongPool();
    }

    function beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        onlyPoolManager
        returns (bytes4)
    {
        _checkPool(key);
        if (initialized) revert AlreadyInitialized();
        // The admission bytecode probe supplies token/manager runtimes, not the external pair.
        // Validate the actual pair atomically when the manager initializes this pool.
        if (address(imd).code.length == 0 || IERC20Metadata(address(imd)).decimals() != 18) {
            revert InvalidConfiguration();
        }
        initialized = true;
        _record(TickMath.getTickAtSqrtPrice(sqrtPriceX96));
        emit PoolBound(PoolId.unwrap(key.toId()));
        return IHooks.beforeInitialize.selector;
    }

    function _specifiedIMD(SwapParams calldata params) private view returns (bool) {
        return (params.amountSpecified < 0) == (params.zeroForOne == (address(imd) < address(hfrog)));
    }

    function _specifiedAmount(SwapParams calldata params) private pure returns (uint256 amount) {
        int256 n = params.amountSpecified;
        if (n == type(int256).min) revert InvalidSwapAmount();
        amount = uint256(n < 0 ? -n : n);
        if (amount == 0 || amount > uint256(uint128(type(int128).max))) revert InvalidSwapAmount();
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        if (!initialized) revert NotInitialized();
        uint256 amount = _specifiedAmount(params);
        uint256 fee;
        if (_specifiedIMD(params)) {
            // Exact-input buys: fee is inside the IMD budget. Exact-output sells: gross up net IMD.
            fee = amount * FEE_BPS / (params.amountSpecified < 0 ? 10000 : 9850);
            if (amount + fee > uint256(uint128(type(int128).max))) revert InvalidSwapAmount();
            _accrue(fee);
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        _checkPool(key);
        if (!initialized) revert NotInitialized();
        int128 imdDelta = address(imd) < address(hfrog) ? delta.amount0() : delta.amount1();
        int128 frogDelta = address(imd) < address(hfrog) ? delta.amount1() : delta.amount0();
        if (imdDelta == 0 || frogDelta == 0) revert NoSwap();
        uint256 amount = uint256(imdDelta < 0 ? -int256(imdDelta) : int256(imdDelta));
        uint256 fee;
        if (_specifiedIMD(params)) {
            uint256 specified = _specifiedAmount(params);
            uint256 charged = specified * FEE_BPS / (params.amountSpecified < 0 ? 10000 : 9850);
            uint256 expected = params.amountSpecified < 0 ? specified - charged : specified + charged;
            // Cannot refund the specified currency from afterSwap; never charge a full-order fee on a partial fill.
            if (amount != expected) revert PartialFillUnsupported();
        } else {
            fee = amount * FEE_BPS / 10000;
            _accrue(fee);
        }
        (, int24 tick,,) = poolManager.getSlot0(key.toId());
        _record(tick);
        return (IHooks.afterSwap.selector, int128(uint128(fee)));
    }

    function _accrue(uint256 fee) private {
        if (fee == 0) return;
        uint256 stakers = fee * 60 / 100;
        uint256 vault = fee * 25 / 100;
        uint256 team = fee - stakers - vault;
        uint256 id = uint256(uint160(address(imd)));
        totalFees += fee;
        totalToStakers += stakers;
        totalToVault += vault;
        totalToTeam += team;
        if (stakers != 0) poolManager.mint(address(staking), id, stakers);
        if (vault != 0) poolManager.mint(address(frog), id, vault);
        if (team != 0) poolManager.mint(address(this), id, team);
        staking.notifyReward(stakers);
        emit FeeAccrued(fee, stakers, vault, team);
    }
}
