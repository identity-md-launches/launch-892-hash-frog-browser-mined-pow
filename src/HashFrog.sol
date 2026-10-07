// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {ClaimReceiver} from "./ClaimReceiver.sol";
import {FrogRouter} from "./FrogRouter.sol";
import {FrogArt} from "./FrogArt.sol";

interface IFrogOracle {
    function consult() external view returns (int24);
    function quoteAtTick(int24 tick, uint128 amount, bool baseIs0) external pure returns (uint256);
}

/// @notice The NFT and its burn-only vault share one contract, with no withdrawal authority.
contract HashFrog is ERC721, ClaimReceiver {
    using SafeERC20 for IERC20;
    uint256 public constant MAX_SUPPLY = 2000;
    uint256 public constant PRICE = 0.0019 ether;
    uint256 public constant INITIAL_TARGET = type(uint256).max >> 20;
    bytes32 public constant GENESIS_SEED = keccak256("Hash Frog / a pond begins / genesis v1");
    address public constant HACKATHON = 0x56e8C9Bd511718508f7410aEE3E8A693588B38F0;
    address public constant TEAM = 0x789C9aDDa69a5880fe70eb4FBC8147F2a54B6363;
    bytes32 internal constant MINT_TX_SLOT = keccak256("hashfrog.minted.this.transaction");
    uint256 public constant MAX_BUYBACK = 100 ether;
    IERC20 public immutable hfrog;
    FrogRouter public immutable router;
    address public immutable hook;
    uint256 public totalMinted;
    uint256 public totalBurned;
    uint256 public target = INITIAL_TARGET;
    bytes32 public lastSeed = GENESIS_SEED;
    uint256 public epochStarted;
    uint256[60] public mintTimes;
    mapping(uint256 => bytes32) public seedOf;
    mapping(bytes32 => bool) private seedUsed;
    mapping(address => uint256) public ethCredit;
    uint256 public ethToHackathon;
    uint256 public ethToTeam;
    uint256 public lastBuyback;
    uint256 public totalBuybackIMD;
    uint256 public totalBoughtHFROG;

    error SoldOut();
    error WrongPrice();
    error StaleSeed();
    error InvalidReferenceBlock();
    error InvalidProof();
    error OneMintPerTransaction();
    error HourFull(uint256 nextSlotAt);
    error HolderOnly();
    error BuybackCooldown(uint256 nextBuybackAt);
    error InvalidBuybackAmount();
    error BuybackSlippage();
    event Mined(uint256 indexed id, address indexed minter, bytes32 seed, uint256 target);
    event Retargeted(uint256 oldTarget, uint256 newTarget, uint256 elapsed);
    event EthPayment(address indexed recipient, uint256 amount, bool sent);
    event Burned(uint256 indexed id, address indexed holder, uint256 hfrogAmount, uint256 imdAmount);
    event Buyback(uint256 imdAmount, uint256 hfrogAmount);

    constructor(IPoolManager manager_, IERC20 hfrog_, IERC20 imd_, FrogRouter router_, address hook_)
        ERC721("Hash Frog", "HASHFROG")
        ClaimReceiver(manager_, imd_, address(0))
    {
        hfrog = hfrog_;
        router = router_;
        hook = hook_;
        epochStarted = block.timestamp;
    }

    /// @dev Preimage is packed: 20-byte sender, 32-byte nonce, 32-byte seed, 32-byte block hash.
    function mine(uint256 nonce, bytes32 expectedSeed, uint256 refBlock)
        external
        payable
        nonReentrant
        returns (uint256 id)
    {
        if (msg.value != PRICE) revert WrongPrice();
        if (totalMinted == MAX_SUPPLY) revert SoldOut();
        if (expectedSeed != lastSeed) revert StaleSeed();
        if (refBlock >= block.number || block.number - refBlock > 64 || blockhash(refBlock) == bytes32(0)) {
            revert InvalidReferenceBlock();
        }
        uint256 oldest = mintTimes[totalMinted % 60];
        if (totalMinted >= 60 && block.timestamp < oldest + 3600) revert HourFull(oldest + 3600);
        bytes32 slot = MINT_TX_SLOT;
        bool already;
        assembly ("memory-safe") { already := tload(slot) }
        if (already) revert OneMintPerTransaction();
        bytes32 seed = keccak256(abi.encodePacked(msg.sender, nonce, expectedSeed, blockhash(refBlock)));
        if (uint256(seed) >= target || seedUsed[seed]) revert InvalidProof();
        assembly ("memory-safe") { tstore(slot, 1) }
        seedUsed[seed] = true;
        mintTimes[totalMinted % 60] = block.timestamp;
        id = ++totalMinted;
        seedOf[id] = seed;
        lastSeed = seed;
        emit Mined(id, msg.sender, seed, target);
        if (id % 8 == 0) _retarget();
        // The NFT goes to the solver; callbacks cannot mint, burn, buy back, or flush recursively.
        _safeMint(msg.sender, id);
        _pay(HACKATHON, PRICE * 85 / 100);
        _pay(TEAM, PRICE * 15 / 100);
    }

    function _retarget() private {
        uint256 elapsed = block.timestamp - epochStarted;
        // 8 mints * 60 seconds, bounded to 4x harder / 2x easier.
        uint256 bounded = elapsed < 120 ? 120 : elapsed > 960 ? 960 : elapsed;
        uint256 old = target;
        uint256 next = bounded > 480 && old > Math.mulDiv(type(uint256).max, 480, bounded)
            ? type(uint256).max
            : Math.mulDiv(old, bounded, 480);
        target = next == 0 ? 1 : next;
        epochStarted = block.timestamp;
        emit Retargeted(old, target, elapsed);
    }

    function freeSlots() public view returns (uint256 count, uint256 nextSlotAt) {
        uint256 used = totalMinted < 60 ? totalMinted : 60;
        count = 60 - used;
        for (uint256 i; i < used; ++i) {
            uint256 expiry = mintTimes[i] + 3600;
            if (block.timestamp >= expiry) count++;
            else if (nextSlotAt == 0 || expiry < nextSlotAt) nextSlotAt = expiry;
        }
        if (totalMinted == MAX_SUPPLY) count = 0;
    }

    /// @dev A bounded call lets a reverting or gas-consuming recipient accumulate credit.
    /// 100k exceeds the hackathon's ~40k need and leaves gas to record failure.
    function _pay(address recipient, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = recipient.call{value: amount, gas: 100_000}("");
        if (!ok) ethCredit[recipient] += amount;
        else if (recipient == HACKATHON) ethToHackathon += amount;
        else ethToTeam += amount;
        emit EthPayment(recipient, amount, ok);
    }

    /// @notice Retry both fixed recipients. Forced ETH is split 85/15 as well.
    function flush() external nonReentrant {
        uint256 a = ethCredit[HACKATHON];
        uint256 b = ethCredit[TEAM];
        uint256 extra = address(this).balance - a - b;
        a += extra * 85 / 100;
        b += extra - extra * 85 / 100;
        ethCredit[HACKATHON] = 0;
        ethCredit[TEAM] = 0;
        _pay(HACKATHON, a);
        _pay(TEAM, b);
    }

    function liveSupply() public view returns (uint256) {
        return totalMinted - totalBurned;
    }

    function burnQuote() public view returns (uint256 hfrogAmount, uint256 imdAmount) {
        uint256 alive = liveSupply();
        if (alive == 0) return (0, 0);
        return (hfrog.balanceOf(address(this)) / alive, (imd.balanceOf(address(this)) + pendingFees()) / alive);
    }

    function burn(uint256 id) external nonReentrant returns (uint256 hfrogAmount, uint256 imdAmount) {
        if (ownerOf(id) != msg.sender) revert HolderOnly();
        _redeemFees();
        (hfrogAmount, imdAmount) = burnQuote();
        _burn(id);
        ++totalBurned;
        if (hfrogAmount != 0) hfrog.safeTransfer(msg.sender, hfrogAmount);
        if (imdAmount != 0) imd.safeTransfer(msg.sender, imdAmount);
        emit Burned(id, msg.sender, hfrogAmount, imdAmount);
    }

    /// @notice Caller can tighten, but cannot disable, the 30-minute TWAP output floor (95%).
    function buyback(uint256 amount, uint256 minOut, uint160 priceLimit, uint256 deadline)
        external
        nonReentrant
        returns (uint256 received)
    {
        if (amount == 0 || amount > MAX_BUYBACK) revert InvalidBuybackAmount();
        if (block.timestamp < lastBuyback + 60) revert BuybackCooldown(lastBuyback + 60);
        IFrogOracle oracle = IFrogOracle(hook);
        uint256 floor = oracle.quoteAtTick(oracle.consult(), uint128(amount), address(imd) < address(hfrog)) * 95 / 100;
        if (floor == 0 || minOut < floor) revert BuybackSlippage();
        lastBuyback = block.timestamp;
        _redeemFees();
        if (amount > imd.balanceOf(address(this))) revert InvalidBuybackAmount();
        imd.forceApprove(address(router), amount);
        (uint256 spent, uint256 bought) = router.swap(true, amount, minOut, priceLimit, deadline);
        imd.forceApprove(address(router), 0);
        totalBuybackIMD += spent;
        totalBoughtHFROG += bought;
        received = bought;
        emit Buyback(spent, bought);
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        return FrogArt.uri(id, seedOf[id]);
    }
}
