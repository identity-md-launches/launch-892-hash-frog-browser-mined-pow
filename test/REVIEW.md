# Contributor test review

This addition tests the existing implementation without changing contracts, dependencies,
configuration, or the earlier contributor's tests. The pinned protected checks and all
three supplied testing references were read. No new contract defect was reproduced.
Passing these tests is not an independent deployment approval or proof of mainnet acceptance.

Final local validation: `forge build` succeeded; `forge test` reported **68 passed,
0 failed, 1 skipped** across 15 suites. The sole skip is the unconfigured mainnet test.
Both new invariant campaigns completed with zero unexpected handler reverts.

## Added coverage

| File | Properties exercised |
| --- | --- |
| `AdversarialFlows.t.sol` | All four swap modes, both IMD currency orders, 1.5% IMD fees and 60/25/15 allocation, claim redemption destinations, failed settlement/slippage rollback, side-effect-free quotes, invalid integer boundaries, wrong pools, spoofed unlocks, immutable wiring, withdrawal/admin selector rejection, pending-claim buyback followed by burn, failed staking entry, reward-claim frequency independence. |
| `NFTFailureProperties.t.sol` | Rejected ERC721 receipt rolls back seed, used proof, transaction latch and payments; ETH recipient reentry fails; wrong prices preserve funds and the proof; reference blockhash binding; eight-mint retarget timing, clamps and integer rounding. |
| `NFTStateful.t.sol` | Three actors mint, transfer, burn, attempt unauthorized burns, donate tokens, force ETH, toggle recipient failures, flush and advance time in random order. Separate ledgers reconcile every burn receipt and every ETH payment/credit, ownership, lifetime issuance and rolling admission history. A deterministic scenario reaches the full rolling window and its exact expiry. |
| `SystemStateful.t.sol` | Real local v4 PoolManager, hook, router, token, vault and staking. Random swaps, staking/exits/claims, redemption, donations, buybacks, burn and elapsed time. Independent fee, principal and payout ledgers reconcile all tracked token balances. Every run ends by withdrawing all staking principal and claiming rewards; only queued rewards and bounded fractional dust may remain. |
| `MainnetFork.t.sol` | Discovers the existing mainnet rehearsal through `forge test`: real PoolManager buys/sells, staking claim, NFT mint forwarding to the live hackathon contract, vault redemption and burn. Explicitly skipped without a configured RPC. |

The previous tests retain their coverage of 2,000 lifetime mints, non-reuse of burned IDs,
the one-mint transaction latch, minter binding, fixed genesis/production-difficulty proof,
85/15 forwarding and gas-consuming receivers, cooldown boundaries, manipulation rejection,
fresh token-only pool liquidity, and 24-hour unstaking.

## Randomized test design

New arithmetic/fee properties use 1,000 fuzz runs. Inline configuration on the concrete
fee-test contracts ensures inherited tests use this count as well.

The NFT campaign uses 256 runs of depth 128 (32,768 calls); the system campaign uses
256 runs of depth 96 (24,576 calls). Both explicitly target handler selectors and enable
`fail-on-revert`. Expected invalid operations use exact revert assertions. Unexpected
reverts fail the campaign. Initial fixtures include funded liabilities, live NFTs and
staking rewards so conservation checks cannot pass solely because everything is zero.

Ghost ledgers are updated only after successful operations. Claims and burn payouts are
checked against recipients' actual token balance changes. The system's aggregate supply
check includes the manager, all companions, fixture, handler, team and all three actors.
An untracked token destination would break this identity. The post-sequence withdrawal
check tests liveness in addition to balance solvency.

The isolated NFT campaign reuses the earlier `FrogHarness` to make mining inexpensive and
reset the transient latch between simulated transactions. It does not alter payment,
ownership, burn, cap or rolling-window logic. The integrated campaign uses the production
contracts and the existing precomputed proof at the real launch difficulty; its single
frog can burn before or after subsequent fee collection and buybacks. The separate NFT
campaign covers multiple holders and repeated burns. Recipient failure code and forced
ETH are test fixtures, not evidence about a deployed mainnet recipient.

## Reproduce

```sh
forge build
forge test
```

The local review placed generated output and cache under the disposable scratch directory:

```sh
forge build --out test/scratch/out --cache-path test/scratch/cache
forge test --out test/scratch/out --cache-path test/scratch/cache
```

No network, FFI, installation, environment mutation, or file under `test/scratch/` is
required by the delivered offline suite. All imports resolve to existing tracked files.

## Mainnet verification still owed

No verified launch IMD/PoolManager addresses or RPC were supplied for this run. The fork
test therefore records a skip, not a pass. To execute it, supply these environment values
without committing secrets or changing `foundry.toml`:

- `HASHFROG_FORK_RPC_URL`: Ethereum mainnet archive RPC.
- `HASHFROG_FORK_BLOCK`: explicit mainnet block number.
- `HASHFROG_FORK_POOL_MANAGER`: coordinator-verified v4 PoolManager address.
- `HASHFROG_FORK_IMD`: coordinator-verified launch IMD address.

Then run `forge test --match-contract MainnetForkTest -vvv`. When an RPC is provided,
missing inputs fail instead of skipping. The rehearsal verifies chain ID, deployed code,
the IMD symbol and decimals, successful real-manager settlement, and that the live
hackathon recipient accepts the NFT payment without creating a failed-send credit.

Live deployment/hosting, browser behavior and third-party audit sign-off are outside this
bounded tests-only contribution. No assertion in this addition certifies those outcomes.
