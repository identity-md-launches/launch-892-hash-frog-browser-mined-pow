# Hash Frog frontend validation

Run on 2026-10-07. These are worker observations, not independent certification. No mainnet transaction or contract deployment was performed. The final source/export retain the original contract code, Foundry settings and Solidity dependencies.

## Commands and results

| Check | Actual result |
| --- | --- |
| `forge build --out test/scratch/out --cache-path test/scratch/cache` | Passed with Solidity 0.8.26; existing lint warnings remain in unmodified contracts. Used to reconstruct ABIs/runtime, not to redeploy. |
| `forge inspect HashFrog storage-layout --json --out test/scratch/out --cache-path test/scratch/cache` | Passed; layout used only for the sample renderer's temporary RPC overrides. |
| `node tools/verify-mainnet.mjs` | Passed on chain 1 at block **26,140,468**. Both attested canonical ABI hashes match; all five application ABIs match compiled artifacts. All five application runtimes match compiled bytes after masking the compiler-listed immutable locations. The PoolManager/IMD are verified as deployed dependencies, not compared against our application build. |
| `npm --prefix web run typecheck` | Passed, strict TypeScript with no emit. The pinned vendored ethers ABI boundary has explicit dynamic declarations; application state, quote and proof structures are typed. |
| `npm --prefix web run build` | Passed after final source corrections. Export: **3,050,887 bytes**, including full runtime dependency licenses. Vite emitted an upstream removable PURE-comment warning and optional wallet chunks above 500 kB; neither is a build failure. WalletConnect loads on demand. |
| `npm --prefix web test` | **10/10 passed**: amounts/slippage, quote binding/expiry, stale proof/reorg handling, actual revert bytes, metadata/countdowns, 100 Keccak vectors, known-difficulty WASM proof, strict target/GPU input layout, complete relative assets, and absence of dependency/cache/archive files in the export. |
| `npm --prefix web run test:browser` | Passed against the final export. **12 local-fork transactions**, all seven routes, mining/mint, gallery/detail, buy/sell and approvals, stake/claim/request/withdraw, buyback/cooldown, burn/acknowledgement, statistics and chain-change gating. See `browser-validation.json`. |
| `git diff --check` | Passed. |

The final browser run served `dist/` at a `/pond/` subpath. Static HTML, JavaScript, CSS, WASM, shader, images and config loaded locally; there were zero uncaught page errors and zero failed local resources. The test uses one-second Anvil blocks to represent a progressing chain. A fresh impersonated local-only account avoids the delegated code that already exists on the familiar Anvil default account addresses on mainnet. It receives test IMD by a local-fork storage edit. No launch runtime code is changed and no constructor/deployment is called. An initial optional Chromium download could not write the read-only default browser cache; validation used the already installed `/opt/google/chrome/chrome` instead. The README specifies a `/tmp` browser-download path for fresh installations.

## Required live checks

The pinned deployment input is preserved in `launch-deployment.json`; network input is in `launch-network.json`. `mainnet-verification.json` records block hash, derived addresses, code hashes, source comparisons and raw revert data.

- Live target: `110427941548649020598956093796432407239217743554726184882600387580788735` (about 1,048,576 expected hashes).
- Rolling-hour slots: **60 free**; lifetime minted: **0** at the recorded block.
- Buy quote: **1 IMD → 296692.620187251687997880 HFROG**, nonzero and obtained from `FrogRouter.quote` by `eth_call`.
- Fake nonce `0`, current seed/reference, exactly `1900000000000000` wei: **`InvalidProof`**, raw selector `0x09bde339`. The UI decoder is tested against these exact bytes.
- Ordinary `tokenURI(1)` reverted `ERC721NonexistentToken` because there were no minted frogs. A sample was read from the deployed renderer with temporary owner/seed state overrides using the live genesis seed. `sample-tokenURI.json` records its metadata. The export labels this as sample artwork, not an existing collectible. This is the explicit limitation of the live tokenURI check; local-fork mint/gallery validation additionally exercised ordinary tokenURI without overrides.

## Better Interface review

Applied the supplied pinned workflow and the core principles of all six domains during implementation, then reviewed the actual export. The final system is documented in root `DESIGN.md`. Attribution/licenses are preserved in `frontend-NOTICE.txt` and `design-reference-LICENSE.txt`.

| Domain | Coverage and evidence | Corrections / findings | Remaining limits |
| --- | --- | --- | --- |
| Accessibility | Native landmarks, links/forms/buttons, bound labels, stable statuses, keyboard focus, reduced-motion guard and 44px actions reviewed in source. Axe WCAG 2/2.1 A/AA: zero violations on all seven views. Native dialog Escape and focus restoration tested. | `site/app.ts:912`, `site/style.css:956`: route focus originally outlined the entire main region. Route focus now goes to its heading with a visible indicator. `site/index.html:326`: permanent burn acknowledged before enabling the action. | No NVDA/VoiceOver session, hardware keyboard/device matrix or full accessibility conformance claim. |
| Layout | All seven views at 320, 390, 768 and 1440 CSS pixels; zero page overflow. Mine checked with 200% CSS zoom and RTL mirror. Desktop Mine and mobile Trade inspected visually. | `site/style.css:422`, `site/style.css:960`: a fee percentage wrapped onto a separate `%` line at phone width. Numeric cells now retain width and fee values stay together. Rechecked on final export. | Native browser zoom, every locale and long translated strings are not exhaustively tested. English is the only implemented locale. |
| Writing | Action labels, disconnected/empty/loading states, fee/quote explanations, cooldowns, irreversible-burn wording and all custom contract errors reviewed. | `site/logic.ts:106`: zero-argument Solidity errors initially caused a secondary decoding exception. Copying ethers Result arguments to a plain array fixes it; live InvalidProof, HourFull and stale-reference tests pass. Clear recovery language replaces raw custom-error names. | Unsupported RPC/wallet errors can still use provider-supplied text. |
| Typography | Computed 16px body and input sizes, 14px labels, 13px fee values; heading hierarchy, measure, wrap behavior and tabular counters checked. | `site/app.ts:56`, `site/app.ts:1171`: small nonzero amounts retain meaningful precision, and minimum output is shown with the exact token-unit decimal value. | System font appearance varies by platform; no external font is required or claimed to have loaded. |
| Colors | Semantic token use checked against rendered surfaces, including panels, fields and primary actions. Measured ratios below. Single dark theme matches the brief. | `site/style.css:1`: consistent role tokens; interactive borders are brighter than structural separators. Error text, selected underline and status copy avoid color-only meaning. No failing measured text pair found. | No light-theme review (not implemented); disabled controls intentionally have reduced opacity. |
| UI | Empty/loading/error/disabled/hover/focus/pressed states reviewed; responsive cards, form validation, dialog and native controls exercised. 120ms press/color transitions are guarded by reduced-motion preference. | `site/app.ts:338`, `site/app.ts:763`: cached art is invalidated after burn-count changes. Quote edits invalidate approval-to-swap eligibility; minimum output stays bound to the reviewed quote. Buttons honor pending work, wallet state and cooldowns. | No 10%-speed animation-panel replay, physical GPU run, WalletConnect pairing or hardware wallet check. |

Measured contrast from browser-computed token values, confirming actual rendered surfaces:

| Foreground / background | Ratio | Threshold |
| --- | --- | --- |
| Main text `#f0efda` / page `#101b17` | 15.16:1 | 4.5:1 normal text |
| Secondary text `#b0bdab` / panel `#17261f` | 8.03:1 | 4.5:1 normal text |
| Primary text `#162113` / fill `#d1ef83` | 12.99:1 | 4.5:1 normal text |
| Error `#ffb7a4` / error surface `#35221e` | 8.98:1 | 4.5:1 normal text |
| Control border `#768b72` / field `#0b1511` | 5.05:1 | 3:1 non-text boundary |
| Focus `#e5f8b6` / panel `#17261f` | 13.82:1 | 3:1 focus indicator |

Rendered evidence: `artifacts/hash-frog-desktop.webp` (1440px) and `artifacts/hash-frog-mobile.webp` (390px, keyboard route focus visible). These are actual screenshots of the final production export. Source review alone is not used to claim visual behavior.

## Consequential assumptions and limits

- The existing vanilla app and Keccak backends were retained and extended with TypeScript/Vite, instead of introducing an unrelated framework. Real geometric on-chain art remains intact; the surrounding UI supplies the pixel styling.
- Mining requires a wallet address because the proof binds the minter. A found proof enables an explicit 0.0019 ETH mint, then the wallet confirms the transaction. Seed/reference changes restart work automatically; full windows stop work.
- “HFROG price” is explicitly the executable **one-HFROG sell quote after fees** in IMD, not an invented USD/spot price.
- Burn estimates can change before inclusion; the deployed burn method has no minimum-output parameter. The UI says so and requires a destruction acknowledgement.
- WalletConnect code/QR UI are bundled but the required public project ID was absent. No shared demo ID was borrowed. Injected wallets work; external pairing remains unverified.
- No static hosting account, destination or publishing capability was supplied. The export was served locally and is ready for the assignment publisher. No durable public URL, external publication or Git commit is claimed. Repository `.git/` was not modified.
- No live write, complete smart-contract audit, screen-reader conformance or physical WebGPU performance claim is made. Successful worker checks are bounded evidence.

## Packaging

`dist/` is complete and uses relative asset paths. Source and new frontend package manifest/lockfile are included. Existing Foundry configuration, dependencies, `.gitmodules`, `.github`, `.env` and root package files were not edited. The original `site/app.js` is replaced by `site/app.ts`; the legacy integration runner now runs the export/fork test without deployment.

No ignore file was changed. Generated dependency directories and browser logs are removed from deliverable paths after validation. The complete packed submission snapshot is measured separately in `submission-size.json`; the local scratch build/test area and temporary Git size-check repository are not submitted.
