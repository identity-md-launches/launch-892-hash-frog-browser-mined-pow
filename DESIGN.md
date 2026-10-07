# Hash Frog design system

## Overview

Hash Frog is a browser-mined NFT and token interface for Ethereum launch 892. The implemented site uses a dark pond palette, square controls, monospace display type, a pixel frog mark and the deployed contract’s own artwork. It retains the existing frogs and mining backends. Each hash route has one visible main heading and a focused task; the mine route pairs an introduction and sample artwork above live counters and the miner.

The source of truth is `site/style.css`, `site/index.html` and the DOM builders in `site/app.ts`. This is a vanilla TypeScript application, not a component framework. No remote font, illustration service or image-generation dependency is used.

## Colors

All colors are sRGB hex tokens in `site/style.css :root`. Dark is the intentional single theme.

| Token | Value | Use |
| --- | --- | --- |
| `--bg` | `#101b17` | Page background |
| `--surface` | `#17261f` | Panels, cards, dialog and notices |
| `--deep` | `#0b1511` | Miner, fields and quote inset |
| `--hover` | `#263a2d` | Neutral control hover |
| `--border` | `#3c5142` | Structural dividers and panel borders |
| `--control-border` | `#768b72` | Interactive boundaries and empty-state frame |
| `--text` | `#f0efda` | Main text |
| `--muted` | `#b0bdab` | Secondary prose, labels and captions |
| `--accent` | `#d1ef83` | Primary actions, selected-nav underline, brand |
| `--accent-hover` / `--focus` | `#e5f8b6` | Primary hover / keyboard outline |
| `--accent-ink` | `#162113` | Text on filled primary controls |
| `--error` | `#ffb7a4` | Error text and destructive action boundary |
| `--error-bg` | `#35221e` | Error surface |

Notices and selected routes communicate with text/underline as well as color. Structural borders are not substitutes for form boundaries. Image outlines use neutral `#ffffff1a`. Contrast measurements and automated audit evidence are in `docs/VALIDATION.md`.

## Typography

`--body` uses the local system sans stack: system-ui, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif. `--mono` uses ui-monospace, Cascadia Code, SFMono-Regular, Consolas, monospace. There are no downloaded fonts. Weight 400 serves body text and counters; 500–600 serves headings and actions; the wordmark uses 800.

Body is 16px with unitless 1.6 line height. Inputs are 16px at all widths. The main display heading is `clamp(2.25rem, 5.4vw, 4.5rem)` with 1.12 line height and −0.045em spacing; ordinary page headings use `clamp(2rem, 4.3vw, 3.5rem)`. Section headings use `clamp(1.5rem, 2.5vw, 2rem)`; third-level headings use 1.25rem. Prose is capped at 65ch and uses pretty wrapping; headings use balanced wrapping. Labels and secondary information use 13–14px; tiny nonessential art labels use 11–12px. Numeric outputs and timers use tabular numbers. Seeds, addresses and quotes wrap; important values are never ellipsized without a full display elsewhere.

## Layout

The shared header, navigation, main and footer have a 1248px maximum width with 40px inline padding. At 980px padding becomes 24px; below 480px it becomes 20px. Repeated spacing uses 8px multiples: 16px between related content, 24px between panels, 32px panel padding, and 48–64px between major regions.

`.split` is two equal columns with 24px gaps, collapsing at 720px. `.hero` starts at 1.2fr/1fr with a 72px gap, shrinks at 980/720px, and becomes one column at 480px. `.stats-strip` uses four columns, then two below 720px. `.gallery` uses four columns, three at 980px, and two at 720px. `.contracts` and `.detail` become one column at 720px. Text inputs and form actions wrap naturally. Small-screen navigation is a horizontally scrollable row with a visible continuation; it does not widen the page.

Layout was checked in Chromium at 320, 390, 768 and 1440 CSS pixels. The browser test also checks a 200% CSS zoom and RTL mirror on Mine; these are bounded checks, not a claim of full RTL localization or every browser’s native zoom behavior.

## Elevation & Depth

The interface is mostly flat. One-pixel borders define structure, darker insets distinguish interactive readouts, and the sample art has an 8px hard shadow in `--deep`. The native wallet dialog uses the browser’s top layer and a `#06100bcc` backdrop. No blur, parallax or staged entrance animation is implemented.

## Shapes

Buttons, form fields and selects use a 2px radius. Panels and cards are square. The original NFT art keeps its own rounded geometry and 64-tile genome mosaic. Its image is never redrawn to match the surrounding pixel treatment. The wordmark’s inline SVG is decorative, uses a 16×16 pixel grid, and has `aria-hidden`.

## Components

- **Navigation:** real hash links with `aria-current="page"`, a visible selected underline, and a skip link. Routes reveal only the active section and move focus to its heading. `#frog/ID` opens details without requiring a server rewrite.
- **Actions:** native buttons, 44px minimum height, neutral / `.primary` / `.danger` styles. Busy, unavailable, cooldown and disconnected states use `disabled`. Hover changes border/background; keyboard focus gets a 3px outline with 4px offset. Disabled controls have 0.45 opacity. A 120ms color/border/scale transition and 0.96 press scale run only when reduced motion is not requested.
- **Fields:** persistent labels, native input/select controls, 48px minimum height, and input modes for amounts/IDs. Trade field errors use `aria-invalid`, `aria-describedby` and an alert; the first invalid field is focused.
- **Panel / terminal:** `.panel`, `.quiet` and `.terminal` reuse the same spacing and border language. Definition lists pair labels with right-aligned numbers. Fee values have reserved nonshrinking width to stay readable on phones.
- **Quote:** `.quote` contains expected output, minimum output and spent amount. Direction, amount or slippage changes invalidate it. Quotes expire after 60 seconds. Both fee components and the combined sequential rate are visible.
- **Gallery card:** a real `.frog-card` link containing the on-chain SVG, frog name and traits. The detail view adds owner and full seed. DOM builders use text nodes for untrusted metadata. Only JSON/SVG data URI formats are accepted. Loading, burned/unavailable and empty states are explicit.
- **Status:** stable polite regions report connection, transaction, miner and quote state. Transaction hashes link to Etherscan. Contract errors use actionable language, including full windows and stale proofs.
- **Wallet dialog:** native `dialog.showModal()` provides background inertness and focus containment. Escape/close return focus to the trigger. Injected providers are discovered with EIP-6963; WalletConnect is lazy loaded and uses the same dialog for its locally generated QR. Unconfigured WalletConnect is explained explicitly.
- **Burn acknowledgement:** owned-frog selector, live vault-share estimate, and a checkbox naming permanent destruction. Payout variability and the contract’s lack of a minimum burn payout are stated beside the action.

## Do’s and Don’ts

Reuse the existing semantic tokens and `.split`/`.panel` patterns for new views. Add a real nav link, a `data-page` section with one h1, and extend the route list. Keep transaction controls unavailable until the deployment and chain are verified. Label estimates and sample artwork explicitly. Preserve full addresses and seeds in detail views. Keep body copy readable and input text at 16px. Do not introduce remote fonts, mock minted frogs, synthetic prices or arbitrary token addresses to fill an empty state.

The six-domain design reference and its documentation method are credited in `docs/frontend-NOTICE.txt`; their original licenses are retained in `docs/design-reference-LICENSE.txt`.
