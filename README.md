# Hash Frog · Launch 892

A static, wallet-connected site for the existing Ethereum mainnet launch. The frontend lives in `site/`; its Vite toolchain and pinned npm lockfile live in `web/`. **Publish `dist/` directly**: it contains the finished production export, local runtime assets, WebGPU shader and WASM miner. No backend or contract deployment is needed.

The seven hash routes are Mine, Gallery (with `#frog/ID` details), Trade, Burn, Vault, Stake and Stats. Public reads work without a wallet. Transactions use an injected EIP-1193/EIP-6963 wallet or the bundled WalletConnect adapter. Wallet account and network changes clear signing/mining state. All addresses originate from the pinned deployment or immutable getters on its hook; see [verification](docs/mainnet-verification.json) and [deployment input](docs/launch-deployment.json).

**Publication status:** production export delivered; no durable hosting destination was supplied, so external publication is not claimed. The local production preview was served and browser-tested. WalletConnect requires the site operator’s public project ID in `site/config.json` (`walletConnectProjectId`); the provided inputs contain none. Its adapter, QR pairing and disconnect flow are included, but pairing is unverified and the UI explains its unconfigured state. Injected wallet flows were exercised on a local fork.

## Install, check, preview and rebuild

Use Node 22.18+ (tested with Node 24.21.0) and npm. Run from the repository root:

```sh
npm --prefix web ci
npm --prefix web run typecheck
npm --prefix web run build
npm --prefix web test
npm --prefix web run preview
```

Preview opens at `http://localhost:4173`. Alternatively, `python3 -m http.server 8080 --directory dist` serves the export without installing anything. Vite uses `base: './'`; hash routing and relative assets also work at a gateway subpath. All art, code, shader and WASM assets are local. Ethereum reads require network access to the two public RPCs in `site/config.json`. WalletConnect additionally contacts its relay.

The build copies public configuration, ABIs and licenses into `dist/`; it never reads private credentials. It has a 4 MiB export budget. The completed submission must additionally fit the 8 MiB packed Git budget. Generated `node_modules`, browser downloads and caches are not deliverables; do not add them, even under nested directories. No ignore file was changed for this task.

## Publish

1. Register a WalletConnect/Reown project for the final HTTPS origin, allow that origin, and set its **public** project ID in `site/config.json`. No private key belongs in this file. The SDK’s [upstream provider documentation](https://github.com/WalletConnect/walletconnect-monorepo/tree/v2.0/providers/ethereum-provider) describes the project ID and connection parameters.
2. Run typecheck, production build and tests above. Preview the resulting export.
3. Upload the **contents of `dist/`** to your static host or IPFS gateway. Use HTTPS for wallets, WebGPU and clipboard access; localhost is also a secure context. The host must serve `.wasm` as `application/wasm`, JavaScript as JavaScript, and JSON as JSON. No rewrites or SPA fallback are necessary because routes use fragments.
4. Verify `/index.html` and a nested gateway path, connect a wallet on chain 1, and request a read-only quote. Keep the source, `web/package.json`, `web/package-lock.json` and complete `dist/` together in the submission. This worker does not modify `.git/` or perform a commit.

Do not run any contract deployment command to publish this site. The legacy contract implementation notes below describe the already deployed system, not a new deployment procedure.

## Validation and live verification

Actual commands, results, design coverage and limitations are recorded in [VALIDATION.md](docs/VALIDATION.md). Machine-readable records: [mainnet](docs/mainnet-verification.json), [browser/fork](docs/browser-validation.json). [DESIGN.md](DESIGN.md) documents the implemented interface.

To repeat the read-only mainnet checks and regenerate the public wiring:

```sh
forge build --out test/scratch/out --cache-path test/scratch/cache
forge inspect HashFrog storage-layout --json --out test/scratch/out --cache-path test/scratch/cache > test/scratch/storage.json
node tools/verify-mainnet.mjs
npm --prefix web run build
```

The script compares canonical Keccak ABI hashes for HFROG and HashFrogHook with the pinned attestation and compares all five ABIs with compiled artifacts when present. It also compares application runtimes against compiled source after masking immutable slots, and reads immutable companion addresses, current target, rolling free slots, a nonzero FrogRouter buy quote, and a fake mint using `eth_call` with exactly 0.0019 ETH. The fake proof was rejected with `InvalidProof`, and the exact returned bytes are covered by the UI error-decoding tests.

At the recorded block, zero frogs had been minted. Ordinary `tokenURI(1)` correctly reverted `ERC721NonexistentToken`. The sample image was obtained by calling **the deployed NFT** with temporary RPC state overrides for owner and genesis seed. This was a read-only renderer check, not a mint, and is labeled as a sample in the site. See [sample metadata](docs/sample-tokenURI.json).

Browser and transaction validation uses Chromium and Anvil. It forks the existing deployed contracts and never deploys contracts:

```sh
# If Chromium is not already installed, keep the download outside the repository:
PLAYWRIGHT_BROWSERS_PATH=/tmp/hashfrog-browsers npm --prefix web exec playwright install chromium
# Point to your installed Chromium executable if different:
HASHFROG_CHROME=/opt/google/chrome/chrome npm --prefix web run test:browser
```

This test serves the exact `dist/` files at a `/pond/` subpath, then changes only the test browser’s config response to a local fork RPC. A local test account receives test IMD through a reversible fork storage edit. All funds, minting, approvals, swaps, burns, staking and time travel in this check exist only on that local fork. It requires public RPC access for the initial fork and a local free TCP port 18546. Its output does not establish mainnet transaction success or hardware WebGPU behavior.

The preserved miner tests independently check 100 Keccak vectors, the known launch-difficulty proof, strict target bounds, packed input ordering and GPU buffer layout. Solidity sources, build configuration and existing dependencies are unchanged.

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
