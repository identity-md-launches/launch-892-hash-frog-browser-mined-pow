# Hash Frog

Browser proof-of-work NFTs, the standard HFROG launch token, an IMD fee hook, a burn vault, and staking. Solidity 0.8.26 / Cancun. No owner, admin, proxy, upgrade, pause, arbitrary call, or rescue mechanism exists in the application contracts.

**Delivery status:** implemented and locally tested. No mainnet deployment or hosted production URL is claimed. This checkout contains no verified IMD address, launch factory configuration, signing capability, hosting destination, or independent reviewer attestation. `launch.parameters.json` is a preparation record, not a factory-issued manifest. `site/config.json` deliberately has no hook address; the site shows this state and disables transactions. The mainnet fork rehearsal is supplied but has not run against the actual launch inputs. See [deployment and operations](docs/DEPLOYMENT.md) and [review status](docs/SECURITY.md).

## Reproduce offline

All contract and browser dependencies are ordinary vendored files. No package install, submodules, CDN, compiler binary, FFI, filesystem cheatcode permission, or environment variables are needed by the default tests. The Foundry worker must provide the pinned compiler.

```sh
forge build
forge test
forge fmt --check
node --test test/site/*.test.mjs
node test/site/integration.mjs
```

The last command starts an isolated local Anvil instance, deploys the real v4 PoolManager and production contracts, mines a real proof with WASM, and drives the DOM application through wallet connection, gallery, buy/sell, staking, delayed withdrawal, claims, buyback, burn, fee redemption, and ETH flush. It requires the Foundry executables and the artifacts from `forge build`. It neither forks nor sends live transactions. Node 22+ recommended; verified here with Node 24.

The Solidity tests include both IMD currency orderings, all four exact-input/output swap modes, a fresh manager with HFROG-only liquidity, fuzzed fee/reward arithmetic, and stateful accounting invariants. NFT harness setters live only under `test/`; production has no difficulty setter. A hard-coded known-answer proof tests the actual initial difficulty. Tests use `vm.getBlockTimestamp()` around warps to avoid compiler assumptions that a transaction's timestamp is constant.

Run the static site without a build step:

```sh
python3 -m http.server 8080 --directory site
```

HTTPS or localhost is needed for browser GPU support. Every dependency is served locally. Regenerate miner backends and ABI files after relevant changes:

```sh
python3 tools/generate-miner.py
node tools/build-miner.mjs
python3 tools/export-abi.py
```

`tools/vendor/wabt.cjs` is the pinned WAT compiler; the delivered `.wasm` is already built. No compilation is needed in a visitor's browser. The WGSL and WAT generators use the same Keccak permutation, independently checked against the vendored ethers implementation. GPU initialization includes a production-difficulty known-answer test. A GPU-less workspace cannot attest to a hardware GPU run; WASM, CPU proof validation and DOM integration are covered locally.

## Contracts and launch wiring

| Contract | Role |
| --- | --- |
| `HFROG` | No-argument ERC-20: 18 decimals, 1 billion tokens minted once to its deployer (the launch factory). |
| `HashFrogHook` | Constructor `(IPoolManager manager, IERC20 token, IERC20 imd, int24 tickSpacing)`. Binds one pool; charges IMD; creates all companions in its constructor. |
| `HashFrog` | ERC-721 plus its own immutable burn vault and buyback function. |
| `FrogStaking` | Active HFROG accounting and IMD rewards, with a 24-hour exit queue. |
| `FrogRouter` | Permissionless single-pool exact-input swaps and reverting simulation quotes. |
| `ClaimReceiver` | Common fixed-destination ERC-6909 fee redemption. |
| `FrogOracle` | Tick accumulator and bounded observation history for buyback protection. |

The factory first deploys `HFROG`, then deploys `HashFrogHook` with `$poolManager`, `$token`, the verified IMD address, and spacing `60`. The hook constructor deploys staking, router, and NFT/vault atomically; there is no second initialization transaction or setter to seize. Read companion addresses from the hook. The manager and token addresses are never hardcoded. IMD code and decimals are validated in beforeInitialize (the isolated admission constructor probe does not install external pair code). Both assets must be standard, non-rebasing, non-taxed 18-decimal ERC-20s; verify actual IMD before release.

The hook validates its address bits in its constructor. Salt mining must use the actual factory's CREATE2 deployer and exact constructor arguments. Permissions are `0x20cc` (8396): beforeInitialize, beforeSwap, afterSwap, beforeSwapReturnDelta, afterSwapReturnDelta. The pool has static LP fee `12500` (1.25%). Pool currencies, fee, spacing, and hook address are checked in every enabled callback. Initialization requires the manager and returns the v4 selector. Other callbacks are not implemented and revert.

Configuration record (the reference wizard has no enum for the requested absence of access control, so `access: null` means **none**, not Ownable):

```json
{
  "hook": "BaseHook",
  "name": "HashFrogHook",
  "pausable": false,
  "currencySettler": true,
  "safeCast": true,
  "transientStorage": false,
  "shares": {"options": false},
  "permissions": {
    "beforeInitialize": true, "afterInitialize": false,
    "beforeAddLiquidity": false, "afterAddLiquidity": false,
    "beforeRemoveLiquidity": false, "afterRemoveLiquidity": false,
    "beforeSwap": true, "afterSwap": true,
    "beforeDonate": false, "afterDonate": false,
    "beforeSwapReturnDelta": true, "afterSwapReturnDelta": true,
    "afterAddLiquidityReturnDelta": false, "afterRemoveLiquidityReturnDelta": false
  },
  "inputs": {}, "access": null, "info": {"license": "MIT"}
}
```

This is a direct minimal implementation of the BaseHook callback pattern using v4-core, not inheritance from the optional OpenZeppelin hooks package. Settlement uses sync/transfer/settle, safe casts are preceded by bounds, and the NFT uses transient storage separately for its one-mint-per-transaction latch. No LP fee override, anti-snipe, router allowlist, user identity inferred from the hook's sender, or trusted `hookData` exists.

## Mining and art

`mine(uint256 nonce, bytes32 expectedSeed, uint256 refBlock)` requires exactly `0.0019 ETH`. The proof is:

```
uint256(keccak256(abi.encodePacked(msg.sender, nonce, expectedSeed, blockhash(refBlock)))) < target
```

Packing is exactly 116 bytes: address (20), nonce (32, big-endian), seed (32), block hash (32). The reference must be one of the previous 64 blocks, with a nonzero hash. `expectedSeed` must equal `lastSeed`. Genesis is `keccak256("Hash Frog / a pond begins / genesis v1")`; each subsequent seed is the preceding proof's digest. The initial target is `type(uint256).max >> 20`, approximately 1,048,576 expected hashes. Difficulty never has a setter.

Every eighth mint multiplies target by elapsed time / 480 seconds, clamping elapsed to [120, 960]. This is at most 4x harder or 2x easier. The first interval begins at deployment, not the first mint. Target stays in [1, 2^256−1]. Independently, a ring of the last 60 timestamps rejects a mint if 60 already fall in `(now−3600, now]`, with `HourFull(nextSlotAt)`. A mint at exactly the oldest timestamp + 3600 is allowed. This is a rolling window, not clock-hour buckets. At most one successful mint of this collection per EVM transaction, across all callers. IDs monotonically increase; burning never restores capacity. Two thousand is the lifetime cap.

85% of each price (0.001615 ETH) is called to `0x56e8c9bd511718508f7410aee3e8a693588b38f0`; 15% (0.000285 ETH) to `0x789C9aDDa69a5880fe70eb4FBC8147F2a54B6363`. Each call receives up to 100,000 gas, enough for the specified ~40,000-gas receiver. Revert or gas exhaustion becomes recipient-specific credit. Anyone may `flush()` both recipients; destinations cannot change. Forced ETH is also split 85/15, with sub-wei division remainder assigned to the team. There is no receive/fallback deposit or other ETH exit.

Art is original SVG, generated on chain by `FrogArt`; JSON and SVG are Base64 data URIs. A separate seed hash derives Moss/Orchid skins and rare Sunmetal (1/32 condition, excluding Moonstone), Moonstone (1/128), Stargazer eyes, Reed crowns and Orbit adornments. All 256 raw seed bits are drawn as a 64-tile, 16-color genome mosaic: every accepted seed is a distinct one-of-one composition, with duplicate seeds explicitly rejected. There are no externally assigned numbered singleton prizes. Traits are deterministic and **grindable** by miners; proof of work is not VRF randomness, an ASIC defense, or a fair lottery. Block producers and faster miners have an advantage. Ethereum reorgs and concurrent mints invalidate work. There is no mining reward other than eligibility to pay for one NFT.

## Swap fees and settlement

Fees are charged only in IMD. Hook fees are in addition to the LP fee and round down in IMD minor units:

| Order | IMD fee definition |
| --- | --- |
| Exact-input buy | `floor(gross IMD budget × 150 / 10000)`; the rest enters the pool. |
| Exact-output buy | `floor(pool IMD input × 150 / 10000)` added to required input. |
| Exact-input sell | `floor(gross pool IMD output × 150 / 10000)` withheld from output. |
| Exact-output sell | `floor(requested net IMD × 150 / 9850)`; pool output is net + fee. |

Specified-IMD fees use beforeSwap; unspecified-IMD fees use afterSwap. Specified-IMD swaps must fully fill the adjusted specified amount; partial fills revert atomically instead of paying a full-order fee on a partial trade. Unspecified-IMD partial fills are charged on the actual IMD delta. Zero-output swaps fail. All successful pool deltas, fees, and settlements balance, tested on a real manager in both currency orders.

For each fee, 60% is assigned to staking, 25% to the frog, and the remainder (15% plus at most 2 minor units of splitting dust) to the team. The manager mints ERC-6909 IMD claims **directly** to the three fixed contracts; no IMD balance is needed before the router settles. Staking is notified immediately in that swap. `pendingFees()` shows unredeemed balances. Anyone may call each recipient's `redeemFees()`; only the fixed destination can receive tokens. The hook's destination is the fixed team address; staking and the frog receive their own tokens. Claims are automatically redeemed before reward payouts, frog burns, and buybacks. Receipt of funds cannot be redirected by the redeemer.

## Vault, burns, and staking assumptions

**Burn denominator:** minted frogs that have not been burned, `totalMinted − totalBurned` immediately before the burn. Unminted frogs do not yet have a vault claim. Thus the only live frog can empty the vault even before sellout; new mints then share future accruals. This interpretation is explicit because counting all 2,000 potential frogs would produce different economics. It must be accepted before launch; there is no setting to change it afterward.

Only the actual NFT holder may burn; an approved operator cannot burn for itself. Both HFROG and IMD payouts are integer `balance / liveSupply`, with pending IMD claims redeemed first. The last live frog receives all remaining dust. Burning destroys the NFT before transfers. Token donations to the vault join the burn balance. No recipient parameter, token rescue, allowance to arbitrary spenders, or withdrawal exists.

Anyone may call `buyback(amount, minOut, priceLimit, deadline)`, spending at most 100 IMD per successful call with at least 60 seconds between successes. The IMD amount is the gross buy budget. Buybacks pay the same hook and LP fees and deliver HFROG only to the vault. They require a nonzero minimum of at least 95% of a 30-minute geometric average-price quote. The 5% band includes swap fees and price impact; callers can demand better execution. An output floor, deadline and v4 price limit are enforced atomically; a failed call does not consume cooldown. The immutable router allowance is exact and reset to zero after each buyback.

The oracle accumulates every post-swap tick and stores up to 64 observations, at least 60 seconds apart. It interpolates the cumulative tick at the 30-minute cutoff. This introduces up to one observation interval of smoothing; it is not an external fair-value feed. The first 30 minutes cannot buy back. Same-transaction spot manipulation has no elapsed-time weight. Sustained price manipulation and thin liquidity remain risks. Burns of unswapped IMD always remain possible. An off-chain keeper pays gas; no caller incentive is deducted from vault funds.

Staking uses a `1e36` accumulator plus global and per-account fractional carry. Rewards belong to active stakes at swap time, even if claims are redeemed later. Fees while no stakes exist are queued and allocated when the first nonzero stake arrives. This first stake can capture the queue by design. Requesting an exit checkpoints earned rewards and removes that amount from active rewards immediately. One exit queue per account: another request restarts the full 24 hours for all pending principal. `unstake()` pays only matured principal; `claim()` remains available during the delay. Rounding dust/fractions stay in the staking contract until earned; they never go to a third party. Token donations to staking are not rewards and have no rescue path.

For operational steps and the remaining release work, see [DEPLOYMENT.md](docs/DEPLOYMENT.md). All dependency revisions and file hashes are recorded in [dependencies.json](dependencies.json).
