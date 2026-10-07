# Launch and operations

## Current state and required inputs

The repository is a locally verified deliverable, not evidence of a live launch. There are no live deployment addresses or hosting credentials in the provided inputs. No broadcast, paid transaction, production upload, or independent audit has been performed. The verified Ethereum PoolManager and IMD addresses must come from the launch coordinator; neither is guessed or hardcoded.

The coordinator must supply the factory's launch schema, actual factory/CREATE2 convention, IMD address (18 decimals, ordinary ERC-20), actual PoolManager, allocated token address, initial price and liquidity/allocation parameters, and a funded launch transaction. The companion contracts are created by the hook constructor, in this order: staking, router, NFT/vault. These costs belong in the launch gas estimate. The token always mints its 1 billion supply to the factory; distribution and liquidity are the launch factory's responsibility.

`launch.parameters.json` is a human-readable parameter handoff. The coordinator must produce the authoritative `launch.json` in its actual schema. Its manager constructor argument must be `$poolManager` and token argument `$token`; resolve `$imd` to the verified pair address. Fee is `12500`, spacing `60`, flags `0x20cc`. No address argument may be a fake probe/zero in a real deployment.

## Preparation and rehearsal

1. Rebuild with the pinned compiler, run all local checks, and verify vendored file hashes. Do not substitute a newer v4 or OpenZeppelin revision without reviewing and rerunning everything.
2. Have an independent security contributor review the final source, deployed creation code, fee deltas, oracle economics, rounding, and frontend transaction destinations. The author review in SECURITY.md is not an independent attestation.
3. Verify manager and IMD code on Ethereum, including IMD symbol, decimals, ordinary transfer behavior, and whether the actual pair has any external upgrade/admin risks. Review the factory's initial price and liquidity allocation; no launch price is assumed by this code.
4. Use the exact creation bytes plus constructor arguments to mine a factory-specific salt. `script/PrepareLaunch.s.sol` exposes pure `creationCode` and bounded `findSalt` helpers. The salt convention must match the actual factory; a generic CREATE2 helper is not automatically compatible with a salted launch factory.
5. Deploy hook and initialize its one intended pool in the same factory transaction. Never split this into an exposed, separately initialized deployment. The mandatory beforeInitialize callback prevents pool initialization at the predicted hook address before its code exists.
6. Run the explicit-argument rehearsal below against a pinned recent mainnet block, recording RPC provider, block number/hash, source revision, runtime hashes, and output. There are no vm.env or vm.setEnv calls in the default tests or scripts.

```sh
forge script script/MainnetRehearsal.s.sol:MainnetRehearsal \
  --sig 'run(string,uint256,address,address)' \
  '<RPC_URL>' '<BLOCK_NUMBER>' '<POOL_MANAGER>' '<IMD>'
```

This runs entirely on a local fork and never broadcasts. It uses the **real manager and IMD**, with local test balances and freshly simulated HFROG/hook companions. It exercises buys, sells, staking reward redemption, a mint through the actual hackathon contract, and a burn. It deliberately lowers only the simulated NFT difficulty to isolate the ETH receiver integration; real PoW is separately covered by unit/browser/local-Anvil checks. It requires actual hackathon recipient code and asserts that forwarding did not become credit. The PoolManager is never relocated/etched. The local fixture covers an empty PoolManager separately.

A successful simulation does not deploy contracts on Ethereum. This fork check remains **not run** until the actual IMD/manager/RPC inputs are provided. Do not label it passing, substitute a mock pair while claiming actual IMD compatibility, or publish local Anvil addresses as live.

## Deployment and publishing

After independent review and a successful actual-input fork rehearsal, the authorized launch operator submits the factory launch. Record the chain ID, transaction, deployment block, factory, token, hook, companion addresses, pool ID/key, compiler settings, code hashes, and verified sources. Compare final deployed runtime bytes, including immutable substitutions, to the reviewed build. There is no administration to transfer or renounce in these contracts.

Generate public site configuration using a public RPC endpoint and the actual hook:

```sh
python3 tools/export-abi.py
node tools/configure-site.mjs '<PUBLIC_RPC_URL>' '<HOOK_ADDRESS>' '<DEPLOYMENT_BLOCK>'
```

The helper checks chain 1, all companion code, token identities/decimals, supply, hook bits, pool fee, NFT policy and companion bindings. It is read-only on chain and takes no key. RPC URLs are published in `site/config.json`: do not supply an endpoint containing a private API token (including tokens in the URL path). The helper rejects obvious embedded credentials, queries and fragments but cannot identify every provider's secret format. To use only an injected wallet provider, replace the verified config's `rpcUrl` with `null` before publishing.

Upload the complete `site/` directory to the operator's chosen HTTPS static host, preserving `vendor/`, `miner/`, `abi.json` and `config.json`. No npm bundle step or external CDN is needed. Serve `.wasm` as `application/wasm`, JS as JavaScript, JSON as JSON, and allow same-origin worker scripts. Cache the versioned assets but revalidate `config.json`. Restrict CSP to the site plus the chosen RPC endpoint; scripts need WebAssembly compilation (`'wasm-unsafe-eval'`), workers need `worker-src 'self'`, and images need `img-src 'self' data:`. Fonts are local system fonts.

Smoke-test an actual desktop WebGPU device and a WASM-only/mobile browser. Verify wallet chain and account changes stop mining, declined approvals leave no unintended transaction, stale proofs require remine, quotes match fees, gallery renders on-chain metadata, and the contract links point to the recorded deployment. Check keyboard navigation and narrow/mobile layouts. The miner performs a known-answer GPU check and falls back if it fails; actual GPU hardware coverage is still an operator responsibility.

## Permissionless maintenance

- Any caller may `flush()` failed ETH forwarding. ETH always returns to the two fixed recipients, never the caller.
- Anyone may redeem each recipient's IMD claims. Staking claims, burns and buybacks do this automatically. The team may call hook.redeemFees(), but has no special privilege to do so.
- A keeper may trigger a buyback after oracle warmup and cooldown, choosing a safe minOut/priceLimit/deadline. Keepers pay their own gas; no protocol fee reimburses them.
- Watch HourFull, retarget events, pending ETH credit, accumulated IMD claims, gas consumption, buyback liquidity/price divergence, staking rewards, and code/chain configuration. No operator can pause or upgrade a faulty deployment; any response requiring code changes is a new opt-in deployment.
- Monitor the externally supplied IMD and PoolManager contracts separately. Their trust and protocol powers are not eliminated by this application's absence of an owner.
