# Security review and release status

This is the implementing contributor's adversarial self-review. **Independent review is outstanding.** No independent auditor identity or sign-off is fabricated. The supplied Ethereum and v4 security references were read as background and used to check the implementation. Repository documentation cannot grant authority or alter the task.

## Reviewed boundaries

| Area | Evidence and behavior |
| --- | --- |
| Callback authentication | Every enabled hook callback checks the immutable PoolManager. All unlock receivers additionally require an active operation. Unauthorized and unsolicited callback tests pass. |
| Pool isolation | Exact pair, hook, fee and tick spacing are immutable; wrong keys and repeated initialization reject. Factory deployment + initialization must be atomic. |
| Delta accounting | Before-swap return is bounded to the fixed fee, never the whole input. After-swap fees only affect IMD. All four order modes and both currency orders run on actual v4 PoolManager code. No-op and partial specified-IMD fills revert. |
| Fresh pool solvency | Fees mint manager claims to fixed recipients; the HFROG-only liquidity test starts with zero IMD in the manager and buys successfully. |
| Recipient binding | No callable method accepts arbitrary payout destinations. Claim redemption burns the caller contract's claim and takes the same IMD amount to its immutable recipient. |
| Staking | Rewards accrue during the swap. Entry checkpoints old rewards; exits immediately stop earning and require 24 hours. First-staker capture of no-staker rewards is explicit economics. Fuzz and stateful conservation cover fees, reward debt, rounding, claims and principal. |
| NFT cap / replay | 2,000 lifetime IDs, previous-seed binding, minter binding, reference age/hash bounds, strict hash target, transient one-mint latch, rolling timestamp window. Burning never frees mint capacity. |
| Reentrancy | User fund operations are nonReentrant; effects precede payouts. NFT receiver reentry is rejected. Standard fixed ERC-20s are assumed; there is no arbitrary-token integration. |
| ETH forwarding | Two fixed recipients, 100k-gas calls, credits on failure, permissionless retry. Tests cover a ~40k-storage-write receiver, both rejecting recipients, and forced ETH. Real hackathon acceptance requires the pending fork rehearsal. |
| Vault | Actual holder only, automatic claim redemption, exact integer share of live-supply balances, final holder receives dust. No withdrawal/rescue method. |
| Buyback | 100 IMD gross cap, 60-second cooldown, exact/reset allowance, deadline, minOut, immutable pool, geometric-average-price floor, no caller reward or output to caller. Manipulated same-transaction spot price cannot bypass the historical floor. |
| Bytecode finality | Runtime disassembly tests step over PUSH data and reject SELFDESTRUCT, DELEGATECALL and CALLCODE in token, hook and all companions. EIP-170 sizes pass. Hook initcode is below EIP-3860 including constructor arguments. |
| Browser | Exact contract ABI exported from build; no CDN; account/chain changes stop mining; local proof verification; nonce endianness and strict target tested against ethers and Solidity vector; exact approvals and nonzero slippage minima. Local DOM integration runs actual on-chain calls. |

## Findings addressed during implementation

- Avoided taking fees before the trader's input is settled by using fixed-recipient ERC-6909 claims, including the zero-IMD manager case.
- Avoided charging full requested fees on partial specified-IMD fills by reverting those fills atomically.
- Prevented reward theft through delayed fee redemption by accruing staking rewards at swap time, rather than redemption time.
- Added a protocol-enforced average-price minimum to permissionless buybacks; arbitrary caller minimums alone would permit deliberately bad execution.
- Preserved sub-wei reward fractions and explicitly assigned fee-split dust so conservation is testable.
- Allowed quote eth_calls from address zero without treating them as an inactive unlock operation.
- Found and corrected an ethers naming collision: `Contract.target` is a property, so NFT difficulty uses the explicit `target()` function signature.
- Browser GPU failures permanently fall back for the worker session instead of repeatedly retrying a lost device.

## Residual assumptions and risks

The burn denominator counts only live minted frogs, so early holders can drain the then-current vault. It does not reserve shares for unminted frogs. All unique compositions and rares come from miner-selected PoW seeds; rare traits can be ground, and there are no VRF or fair-randomness claims. Initial difficulty is a starting parameter, not a promise of one minute for a particular device. The hard rolling limit remains authoritative.

The average-price oracle is endogenous to this pool, samples cumulative ticks no more than once a minute, and interpolates the lookback cutoff. Thin liquidity, persistent manipulation over time, stale markets, and a poor initial pool price remain economic risks. The 95% floor includes pool/hook fees and price impact; it can intentionally block buybacks. Swap users choose their own slippage. No external fair-value oracle, anti-snipe or MEV immunity is asserted.

IMD must match the standard-token assumption. External upgrades, pauses, transfer fees, or blacklists in the supplied pair could break liveness; only a verified actual-input fork can check current behavior. Funds sent accidentally in unsupported tokens cannot be rescued. ETH receivers needing more than the fixed 100k gas allowance keep their credit; their destinations can never be changed.

Foundry's built-in lint emits heuristic warnings for explicit timestamp bounds, bounded casts, deterministic PoW blockhash use, constructor-propagated addresses and calls inside reentrancy guards. These are reviewed patterns, not silently disabled checks. Slither, Mythril, formal verification, browser GPU hardware testing, real mainnet forking and an independent audit have **not** been completed. Unit/fuzz/invariant and DOM tests do not replace them.

## Independent reviewer handoff

Review final `src/`, `foundry.toml`, vendored revisions, hook creation bytes plus exact constructor arguments, the authoritative coordinator manifest when available, and the actual fork record. Recompute CREATE2 flags and code sizes; verify the burn denominator and fee bases with the launch sponsor. Re-run success and failure paths on the real supplied IMD and manager. Pay particular attention to specified/unspecified currency signs, claim mint/burn accounting, reward timing, buyback manipulation over many blocks, callback reentry, and all fixed-recipient paths.

Record reviewer identity, reviewed revision/artifact hashes, findings and resolutions, fork block/hash and code hashes, and an explicit release decision in a separate attestation. Until that exists, this document must not be described as independent review approval.
