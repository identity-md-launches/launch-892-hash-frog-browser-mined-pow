import {
  BrowserProvider,
  JsonRpcProvider,
  FallbackProvider,
  Contract,
  formatEther,
  isAddress,
  toBeHex,
  keccak256,
} from "./vendor/ethers.js";
import { validProof } from "./miner/common.js";
import {
  MINT_VALUE,
  parseAmount,
  parseSlippage,
  makeQuote,
  quoteValid,
  staleProof,
  countdown,
  decodeMetadata,
  contractError,
} from "./logic";
import type { ProofJob, Quote } from "./logic";
type Config = {
  chainId: number;
  hook: string;
  addresses: Record<string, string>;
  codeHashes: Record<string, string>;
  rpcUrls: string[];
  explorer: string;
  repoUrl: string;
  walletConnectProjectId: string;
};
type State = {
  head: any;
  minted: bigint;
  burned: bigint;
  slots: bigint;
  nextSlot: bigint;
  target: bigint;
  seed: string;
  lastBuyback: bigint;
  vaultIMD: bigint;
  position?: any;
  earned?: bigint;
  balance?: bigint;
  readAt: number;
};
const $ = <T extends HTMLElement = HTMLElement>(id: string) =>
  document.getElementById(id) as T;
const input = (id: string) => $(id) as HTMLInputElement;
const button = (id: string) => $(id) as HTMLButtonElement;
const show = (id: string, value: unknown) => {
  $(id).textContent = String(value);
};
const fmt = (v: bigint, digits = 6) => {
  const value = Number(formatEther(v));
  const precision =
    value === 0
      ? digits
      : Math.min(
          18,
          Math.max(digits, Math.ceil(-Math.log10(Math.abs(value))) + 3),
        );
  return value.toLocaleString(undefined, { maximumFractionDigits: precision });
};
const short = (a: string) => a.slice(0, 6) + "…" + a.slice(-4);
const notice = (text: string, error = false) => {
  show("notice", text);
  $("notice").classList.toggle("error", error);
};
const fail = (e: any) => notice(contractError(e, abis).text, true);
const el = (tag: string, text?: string, className?: string) => {
  const n = document.createElement(tag);
  if (text) n.textContent = text;
  if (className) n.className = className;
  return n;
};
const dialog = $<HTMLDialogElement>("wallet-dialog");
let config: Config,
  abis: Record<string, any[]> = {},
  provider: any,
  wallet: any,
  signer: any,
  account = "",
  rawWallet: any;
let hook: any, frog: any, token: any, imd: any, staking: any, router: any;
let ready = false,
  busy = false,
  refreshing = false,
  quoteBusy = false,
  connecting = false;
let state: State | null = null,
  quote: Quote | null = null,
  worker: Worker | null = null,
  job: ProofJob | null = null,
  solution: (ProofJob & { nonce: string }) | null = null,
  mining = false,
  jobNumber = 0;
let page = "mine",
  galleryPage = 0,
  galleryRun = 0,
  ownedRun = 0,
  detailRun = 0,
  owned: number[] = [],
  ownedKey = "",
  galleryKey = "",
  chainNow = 0,
  clockAt = Date.now();
const cachedFrogs = new Map<number, ReturnType<typeof decodeMetadata>>();
const txIds = [
  "start-mining",
  "mint",
  "swap",
  "burn-button",
  "buyback",
  "stake-button",
  "request-exit",
  "claim",
  "withdraw-stake",
  "flush",
  "redeem",
];
function chainTime() {
  return chainNow + (Date.now() - clockAt) / 1000;
}
function buttons() {
  const can =
    ready && !!state && Date.now() - state.readAt < 45000 && !busy && !!account;
  for (const id of txIds) button(id).disabled = !can;
  button("start-mining").disabled ||=
    mining || !!solution || state?.slots === 0n || state?.minted === 2000n;
  button("stop-mining").disabled = !mining && !solution;
  button("mint").disabled ||= !solution || state?.slots === 0n;
  button("quote-trade").disabled = !ready || quoteBusy;
  let valid = false;
  try {
    valid = quoteValid(
      quote,
      input("side").value === "buy",
      parseAmount(input("trade-amount").value),
      parseSlippage(input("slippage").value),
    );
  } catch {}
  button("swap").disabled ||= !valid;
  button("burn-button").disabled ||=
    !input("burn-confirm").checked || !input("burn-id").value;
  button("buyback").disabled ||=
    !state ||
    chainTime() < Number(state.lastBuyback) + 60 ||
    state.vaultIMD === 0n;
  button("claim").disabled ||= !state?.earned;
  button("withdraw-stake").disabled ||=
    !state?.position?.exiting || chainTime() < Number(state.position.unlockAt);
  button("request-exit").disabled ||= !state?.position?.active;
  button("connect").disabled = connecting;
}
function stopMining(text = "Mining stopped.") {
  mining = false;
  worker?.terminate();
  worker = null;
  job = null;
  solution = null;
  show("hashrate", "0 H/s");
  show("eta", "—");
  show("backend", "IDLE");
  show("miner-status", text);
  buttons();
}
async function assertWallet() {
  if (!ready || !state || !signer || !account)
    throw new Error("Connect a wallet on Ethereum mainnet to continue.");
  if (Date.now() - state.readAt > 45000)
    throw new Error(
      "Live data is out of date. Refresh data before submitting.",
    );
  const [chain, accounts] = await Promise.all([
    rawWallet.request({ method: "eth_chainId" }),
    rawWallet.request({ method: "eth_accounts" }),
  ]);
  if (BigInt(chain) !== 1n)
    throw new Error("Wrong network. Switch your wallet to Ethereum mainnet.");
  if (accounts[0]?.toLowerCase() !== account.toLowerCase())
    throw new Error("Wallet account changed. Reconnect before continuing.");
}
async function sent(tx: any) {
  notice("Transaction submitted. Waiting for confirmation…");
  const a = el("a", " View transaction ↗") as HTMLAnchorElement;
  a.href = config.explorer + "/tx/" + tx.hash;
  a.target = "_blank";
  a.rel = "noreferrer";
  $("notice").append(a);
  const receipt = await tx.wait();
  if (receipt.status !== 1)
    throw new Error("Transaction reverted. Refresh data and try again.");
  return receipt;
}
async function transaction(label: string, fn: () => Promise<unknown>) {
  if (busy) return;
  busy = true;
  buttons();
  try {
    await assertWallet();
    notice(label + " — confirm in your wallet.");
    await fn();
    notice(label + " confirmed.");
    await refresh();
  } catch (e) {
    const error = contractError(e, abis);
    notice(error.text, true);
    if (error.name === "StaleSeed" || error.name === "InvalidReferenceBlock") {
      await restartMining(error.text);
    }
    if (error.name === "HourFull") {
      stopMining(error.text);
      await refresh();
    }
  } finally {
    busy = false;
    buttons();
  }
}
async function approve(asset: any, spender: string, value: bigint) {
  await assertWallet();
  if ((await asset.allowance(account, spender)) < value) {
    notice(
      "Approve only this amount in your wallet. The action follows after approval.",
    );
    await sent(await asset.connect(signer).approve(spender, value));
    await assertWallet();
  }
}
async function deadline() {
  return BigInt((await provider.getBlock("latest")).timestamp + 300);
}
async function initialize() {
  [config, abis] = await Promise.all(
    ["config.json", "abi.json"].map(async (f) => {
      const r = await fetch(new URL(f, document.baseURI));
      if (!r.ok) throw new Error("Unable to load " + f + ". Refresh the page.");
      return r.json();
    }),
  );
  if (config.chainId !== 1 || !isAddress(config.hook))
    throw new Error("Launch configuration is unavailable.");
  provider = new FallbackProvider(
    config.rpcUrls.map((url, i) => ({
      provider: new JsonRpcProvider(url, 1, {
        staticNetwork: true,
        cacheTimeout: -1,
      }),
      priority: i + 1,
      weight: 1,
      stallTimeout: 1400,
    })),
    1,
    { quorum: 1, cacheTimeout: -1 },
  );
  const chain = await provider.providerConfigs[0].provider.send(
    "eth_chainId",
    [],
  );
  if (BigInt(chain) !== 1n)
    throw new Error("Read provider is not Ethereum mainnet.");
  hook = new Contract(config.hook, abis.HashFrogHook, provider);
  const [f, t, i, s, r, initialized, flags, pool] = await Promise.all([
    hook.frog(),
    hook.hfrog(),
    hook.imd(),
    hook.staking(),
    hook.router(),
    hook.initialized(),
    hook.FLAGS(),
    hook.poolKey(),
  ]);
  if (
    !initialized ||
    flags !== 0x20ccn ||
    pool.fee !== 12500n ||
    pool.tickSpacing !== 60n
  )
    throw new Error("The pool does not match this launch.");
  for (const [name, address] of Object.entries({
    HashFrog: f,
    HFROG: t,
    IMD: i,
    FrogStaking: s,
    FrogRouter: r,
  }))
    if (address.toLowerCase() !== config.addresses[name].toLowerCase())
      throw new Error(name + " deployment binding mismatch.");
  await Promise.all(
    Object.entries(config.codeHashes).map(async ([name, hash]) => {
      if (keccak256(await provider.getCode(config.addresses[name])) !== hash)
        throw new Error(
          name + " deployed code does not match the verified launch.",
        );
    }),
  );
  frog = new Contract(f, abis.HashFrog, provider);
  token = new Contract(t, abis.HFROG, provider);
  imd = new Contract(i, abis.HFROG, provider);
  staking = new Contract(s, abis.FrogStaking, provider);
  router = new Contract(r, abis.FrogRouter, provider);
  const [td, id, price, max] = await Promise.all([
    token.decimals(),
    imd.decimals(),
    frog.PRICE(),
    frog.MAX_SUPPLY(),
  ]);
  if (td !== 18n || id !== 18n || price !== MINT_VALUE || max !== 2000n)
    throw new Error("Launch policy mismatch.");
  for (const c of [frog, staking, router])
    if ((await c.hook()).toLowerCase() !== config.hook.toLowerCase())
      throw new Error("Companion contract mismatch.");
  $("contracts").replaceChildren();
  for (const [name, address] of Object.entries(config.addresses)) {
    const a = el(
      "a",
      name.replace("HashFrog", "Hash Frog "),
    ) as HTMLAnchorElement;
    a.href = config.explorer + "/address/" + address;
    a.target = "_blank";
    a.rel = "noreferrer";
    a.append(el("span", address + " ↗"));
    $("contracts").append(a);
  }
  ($("source-link") as HTMLAnchorElement).href = config.repoUrl;
  ready = true;
  await refresh();
  if (!state)
    throw new Error("Live data could not load. Refresh data to retry.");
  notice(
    "The pond is live. Connect a wallet when you’re ready to mine or trade.",
  );
  buttons();
}
async function refresh() {
  if (!ready || refreshing) return;
  refreshing = true;
  button("refresh").disabled = true;
  try {
    const head = await provider.getBlock("latest"),
      opts = { blockTag: head.number },
      fa = config.addresses.HashFrog;
    const [
      minted,
      burned,
      slots,
      target,
      seed,
      hackEth,
      teamEth,
      creditA,
      creditB,
      vaultToken,
      vaultIMD,
      pending,
      burnQuote,
      rewards,
      claimed,
      totalStake,
      lastBuyback,
    ] = await Promise.all([
      frog.totalMinted(opts),
      frog.totalBurned(opts),
      frog.freeSlots(opts),
      frog["target()"](opts),
      frog.lastSeed(opts),
      frog.ethToHackathon(opts),
      frog.ethToTeam(opts),
      frog.ethCredit(config.addresses.Hackathon, opts),
      frog.ethCredit(config.addresses.Team, opts),
      token.balanceOf(fa, opts),
      imd.balanceOf(fa, opts),
      frog.pendingFees(opts),
      frog.burnQuote(opts),
      staking.totalRewards(opts),
      staking.totalClaimed(opts),
      staking.totalStaked(opts),
      frog.lastBuyback(opts),
    ]);
    if (state && state.burned !== burned) cachedFrogs.clear();
    state = {
      head,
      minted,
      burned,
      slots: slots[0],
      nextSlot: slots[1],
      target,
      seed,
      lastBuyback,
      vaultIMD: vaultIMD + pending,
      readAt: Date.now(),
    };
    chainNow = head.timestamp;
    clockAt = Date.now();
    show("launch-status", "Live · block " + head.number.toLocaleString());
    show("minted", minted);
    show("stats-minted", minted + " / 2,000");
    show("slots", slots[0]);
    show("burned", burned);
    show("living", minted - burned);
    show(
      "next-slot",
      minted === 2000n
        ? "All frogs minted"
        : slots[0] > 0n
          ? "Available now"
          : new Date(Number(slots[1]) * 1000).toLocaleTimeString(),
    );
    show(
      "difficulty",
      (Number(1n << 256n) / Number(target)).toLocaleString(undefined, {
        maximumFractionDigits: 0,
      }),
    );
    show("target", toBeHex(target, 32));
    show("hack-eth", fmt(hackEth) + " ETH");
    show("team-eth", fmt(teamEth) + " ETH");
    show("eth-credit", fmt(creditA + creditB) + " ETH");
    show("vault-hfrog", fmt(vaultToken));
    show("vault-imd", fmt(vaultIMD + pending));
    show(
      "burn-share",
      fmt(burnQuote[0]) + " HFROG + " + fmt(burnQuote[1]) + " IMD",
    );
    show("rewards", fmt(rewards) + " IMD");
    show("claimed", fmt(claimed) + " IMD");
    show("total-stake", fmt(totalStake) + " HFROG");
    if (account) {
      const current = account;
      const [position, earned, balance] = await Promise.all([
        staking.positions(current, opts),
        staking.earned(current, opts),
        token.balanceOf(current, opts),
      ]);
      if (account === current) {
        state.position = position;
        state.earned = earned;
        state.balance = balance;
        show("my-stake", fmt(position.active) + " HFROG");
        show("my-exit", fmt(position.exiting) + " HFROG");
        show("my-earned", fmt(earned) + " IMD");
        show("token-balance", "Available: " + fmt(balance) + " HFROG");
      }
    }
    if ((mining || solution) && job) {
      if (slots[0] === 0n || minted === 2000n)
        stopMining(
          minted === 2000n
            ? "All 2,000 frogs are minted."
            : "Mint window full. Wait for the next free slot.",
        );
      else if (staleProof(job, seed, target, head.number))
        await restartMining(
          "The seed or reference changed. Mining continues on a fresh puzzle.",
          false,
        );
    }
    tick();
    if (page === "gallery") await loadGallery();
    if (page === "burn") await loadOwned();
    if (page === "stats") {
      try {
        const [, out] = await router.quote.staticCall(
          false,
          10n ** 18n,
          0,
          opts,
        );
        show("hfrog-price", fmt(out, 12) + " IMD");
      } catch {
        show("hfrog-price", "Quote unavailable — refresh to retry");
      }
    }
    if (page === "vault") {
      try {
        await hook.consult(opts);
        show("oracle-status", "The 30-minute price history is available.");
      } catch {
        show(
          "oracle-status",
          "The 30-minute price history is not ready. Try again later.",
        );
      }
    }
  } catch (e) {
    show("launch-status", "Connection interrupted · values may be outdated");
    notice(
      "Live refresh failed. Check your connection and refresh data. " +
        contractError(e, abis).text,
      true,
    );
  } finally {
    refreshing = false;
    button("refresh").disabled = false;
    buttons();
  }
}
function tick() {
  if (state) {
    show(
      "buyback-status",
      chainTime() >= Number(state.lastBuyback) + 60
        ? "Cooldown ready · one buyback per 60 seconds"
        : "Next buyback in " +
            countdown(Number(state.lastBuyback) + 60, chainTime()),
    );
    show(
      "exit-time",
      !account
        ? "Connect wallet"
        : !state.position?.exiting
          ? "No pending withdrawal"
          : countdown(Number(state.position.unlockAt), chainTime()),
    );
  }
  if (quote && Date.now() - quote.at >= 60000) {
    quote = null;
    show("trade-quote", "Quote expired. Get a fresh quote to continue.");
  }
  buttons();
}
function clearAccount(text: string) {
  account = "";
  signer = null;
  wallet = null;
  owned = [];
  ownedKey = "";
  ownedRun++;
  quote = null;
  stopMining(text);
  show("connect", "Connect wallet ↗");
  for (const id of ["my-stake", "my-exit", "my-earned"]) show(id, "—");
  if (state) {
    state.position = undefined;
    state.earned = undefined;
    state.balance = undefined;
  }
  show("token-balance", "Connect your wallet to view your balance.");
  show("owned-status", "Connect your wallet to load your frogs.");
  input("burn-id").replaceChildren(new Option("Select a frog", ""));
  $("burn-preview").replaceChildren();
  input("burn-confirm").checked = false;
  show("wallet-status", text);
  show("miner-status", text);
  buttons();
}
const discovered = new Map<string, { name: string; provider: any }>();
window.addEventListener("eip6963:announceProvider", ((e: CustomEvent) => {
  if (e.detail?.provider?.request) {
    discovered.set(e.detail.info.uuid, {
      name: e.detail.info.name,
      provider: e.detail.provider,
    });
    renderWallets();
  }
}) as EventListener);
window.dispatchEvent(new Event("eip6963:requestProvider"));
function renderWallets() {
  const list = $("injected-wallets");
  list.replaceChildren();
  const entries = [...discovered.values()];
  if (!entries.length && (window as any).ethereum)
    entries.push({
      name: "Browser wallet",
      provider: (window as any).ethereum,
    });
  for (const item of entries) {
    const b = el("button", "Connect " + item.name) as HTMLButtonElement;
    b.onclick = () => connectWallet(item.provider);
    list.append(b);
  }
  if (!entries.length)
    list.append(
      el(
        "p",
        "No browser wallet detected. Open this site in your wallet’s browser, or use WalletConnect.",
        "fine",
      ),
    );
  button("disconnect").hidden = !account;
}
let detach: () => void = () => {};
async function connectWallet(raw: any) {
  if (connecting) return;
  connecting = true;
  buttons();
  show("wallet-status", "Confirm the connection in your wallet…");
  try {
    detach();
    rawWallet = raw;
    const accounts = await raw.request({ method: "eth_requestAccounts" });
    const chain = await raw.request({ method: "eth_chainId" });
    const onAccounts = () => {
      clearAccount("Wallet account changed. Reconnect to continue.");
      renderWallets();
    };
    const onChain = () => {
      clearAccount(
        "Wrong network or changed network. Reconnect on Ethereum mainnet.",
      );
      button("switch-network").hidden = false;
      notice(
        "Wallet network changed. Switch to Ethereum mainnet and reconnect.",
        true,
      );
    };
    raw.on?.("accountsChanged", onAccounts);
    raw.on?.("chainChanged", onChain);
    raw.on?.("disconnect", onAccounts);
    detach = () => {
      raw.removeListener?.("accountsChanged", onAccounts);
      raw.removeListener?.("chainChanged", onChain);
      raw.removeListener?.("disconnect", onAccounts);
    };
    if (BigInt(chain) !== 1n) {
      clearAccount("Wrong network. Switch to Ethereum mainnet to continue.");
      button("switch-network").hidden = false;
      return;
    }
    if (!accounts.length)
      throw new Error("No wallet account was selected. Try connecting again.");
    wallet = new BrowserProvider(raw);
    signer = await wallet.getSigner();
    account = await signer.getAddress();
    show("connect", short(account) + " ↗");
    button("switch-network").hidden = true;
    dialog.close();
    show("miner-status", "Wallet connected. Start mining when you’re ready.");
    notice("Wallet connected on Ethereum mainnet.");
    ownedKey = "";
    galleryKey = "";
    await refresh();
    if (page === "burn") await loadOwned();
    if (page === "gallery") await loadGallery(true);
  } catch (e) {
    show("wallet-status", contractError(e, abis).text);
    fail(e);
  } finally {
    connecting = false;
    buttons();
  }
}
button("connect").onclick = () => {
  renderWallets();
  dialog.showModal();
};
button("close-wallet").onclick = () => dialog.close();
button("switch-network").onclick = async () => {
  try {
    await rawWallet.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId: "0x1" }],
    });
    await connectWallet(rawWallet);
  } catch (e) {
    show("wallet-status", contractError(e, abis).text);
  }
};
button("disconnect").onclick = async () => {
  detach();
  const raw = rawWallet;
  rawWallet = null;
  clearAccount("Wallet disconnected. Connect to start mining.");
  await raw?.disconnect?.();
  dialog.close();
};
let wc: any;
button("walletconnect").onclick = async () => {
  if (!config?.walletConnectProjectId) {
    show(
      "wallet-status",
      "WalletConnect is not configured for this deployment. Use an installed wallet to continue.",
    );
    return;
  }
  button("walletconnect").disabled = true;
  show("wallet-status", "Opening WalletConnect…");
  try {
    const { createWalletConnect } = await import("./walletconnect");
    wc ??= await createWalletConnect(
      config.walletConnectProjectId,
      config.rpcUrls[0],
      (uri, image) => {
        $("wc-pairing").hidden = false;
        ($("wc-qr") as HTMLImageElement).src = image;
        input("wc-uri").value = uri;
        show("wallet-status", "Scan the QR code with your wallet.");
      },
    );
    await wc.connect();
    $("wc-pairing").hidden = true;
    await connectWallet(wc);
  } catch (e) {
    show("wallet-status", contractError(e, abis).text);
  } finally {
    button("walletconnect").disabled = false;
  }
};
button("copy-pairing").onclick = async () => {
  try {
    await navigator.clipboard.writeText(input("wc-uri").value);
    show("wallet-status", "Pairing link copied.");
  } catch {
    input("wc-uri").select();
    show("wallet-status", "Select and copy the pairing link.");
  }
};
async function frogData(id: number) {
  if (cachedFrogs.has(id)) return cachedFrogs.get(id)!;
  const data = decodeMetadata(await frog.tokenURI(id));
  cachedFrogs.set(id, data);
  return data;
}
async function loadOwned() {
  if (!account || !state) return;
  const key =
    account + "/" + state.minted + "/" + state.burned + "/" + state.head.number;
  if (ownedKey === key) return;
  const run = ++ownedRun,
    owner = account;
  show("owned-status", "Checking which frogs you own…");
  const found: number[] = [];
  for (let start = 1; start <= Number(state.minted); start += 24) {
    const ids = Array.from(
      { length: Math.min(24, Number(state.minted) - start + 1) },
      (_, i) => start + i,
    );
    const result = await Promise.all(
      ids.map(async (id) => {
        try {
          return (await frog.ownerOf(id)).toLowerCase() === owner.toLowerCase()
            ? id
            : 0;
        } catch (e) {
          if (contractError(e, abis).name === "ERC721NonexistentToken")
            return 0;
          throw e;
        }
      }),
    );
    if (run !== ownedRun || owner !== account) return;
    found.push(...result.filter(Boolean));
  }
  owned = found;
  ownedKey = key;
  const select = input("burn-id"),
    previous = select.value;
  select.replaceChildren(new Option("Select a frog", ""));
  for (const id of owned)
    select.append(new Option("Hash Frog #" + id, String(id)));
  if (owned.includes(Number(previous))) select.value = previous;
  show(
    "owned-status",
    owned.length
      ? `${owned.length} frog${owned.length === 1 ? "" : "s"} owned by ${short(account)}.`
      : "This wallet has no frogs. Mine a frog to join the pond.",
  );
  buttons();
}
async function loadGallery(force = false) {
  if (!state) return;
  const mine = input("gallery-filter").value === "mine";
  const key = `${state.minted}/${state.burned}/${galleryPage}/${mine}/${account}`;
  if (!force && galleryKey === key) return;
  galleryKey = key;
  const run = ++galleryRun;
  show("gallery-status", "Reading on-chain frogs…");
  try {
    if (mine) {
      if (!account) {
        $("frogs").replaceChildren(
          el("p", "Connect your wallet to see your frogs.", "empty"),
        );
        show("gallery-status", "Wallet not connected.");
        return;
      }
      await loadOwned();
    }
    const all = mine
      ? [...owned].sort((a, b) => b - a)
      : Array.from(
          { length: Number(state.minted) },
          (_, i) => Number(state!.minted) - i,
        );
    galleryPage = Math.min(
      galleryPage,
      Math.max(0, Math.ceil(all.length / 12) - 1),
    );
    const ids = all.slice(galleryPage * 12, galleryPage * 12 + 12);
    const results = await Promise.all(
      ids.map(async (id) => {
        try {
          return { id, data: await frogData(id), error: "" };
        } catch (e) {
          return {
            id,
            data: null,
            error:
              contractError(e, abis).name === "ERC721NonexistentToken"
                ? "Burned frog"
                : "Unable to load · refresh to retry",
          };
        }
      }),
    );
    if (run !== galleryRun) return;
    $("frogs").replaceChildren();
    if (!ids.length) {
      const box = el("div", undefined, "empty");
      box.append(
        el(
          "h2",
          mine
            ? "No frogs in this wallet."
            : "The pond is waiting for its first frog.",
        ),
        el("p", "Mine a valid proof, then mint to add a frog to the gallery."),
      );
      const a = el("a", "Go to the miner →", "button") as HTMLAnchorElement;
      a.href = "#mine";
      box.append(a);
      $("frogs").append(box);
    }
    for (const { id, data, error } of results) {
      const a = el("a", undefined, "frog-card") as HTMLAnchorElement;
      a.href = "#frog/" + id;
      if (data) {
        const img = new Image();
        img.src = data.image;
        img.alt = data.name;
        img.width = 320;
        img.height = 320;
        img.loading = "lazy";
        a.append(
          img,
          el("h2", data.name),
          el(
            "p",
            data.attributes
              .filter((a) => a.trait_type !== "Genome")
              .map((a) => a.value)
              .join(" · "),
          ),
        );
      } else {
        a.append(el("h2", "Frog #" + id), el("p", error));
      }
      $("frogs").append(a);
    }
    button("gallery-prev").disabled = galleryPage === 0;
    button("gallery-next").disabled = (galleryPage + 1) * 12 >= all.length;
    show(
      "gallery-page",
      `Page ${galleryPage + 1} of ${Math.max(1, Math.ceil(all.length / 12))}`,
    );
    show(
      "gallery-status",
      `${all.length} ${mine ? "owned frogs" : "lifetime IDs"} · newest first`,
    );
  } catch (e) {
    galleryKey = "";
    show(
      "gallery-status",
      "Gallery could not load. Refresh data to try again.",
    );
    fail(e);
  }
}
async function loadDetail(id: number) {
  const run = ++detailRun,
    box = $("detail-content");
  box.replaceChildren(el("p", "Reading frog #" + id + " from Ethereum…"));
  try {
    if (!Number.isInteger(id) || id < 1 || id > 2000)
      throw new Error("Choose a frog ID between 1 and 2,000.");
    if (!ready) return;
    const [data, owner, seed] = await Promise.all([
      frogData(id),
      frog.ownerOf(id),
      frog.seedOf(id),
    ]);
    if (run !== detailRun) return;
    const img = new Image();
    img.src = data.image;
    img.alt = data.name;
    const text = el("div");
    text.append(
      el("p", "On-chain original", "eyebrow"),
      el("h1", data.name),
      el("p", data.description),
    );
    const dl = el("dl");
    for (const trait of data.attributes) {
      if (trait.trait_type === "Genome") continue;
      const row = el("div");
      row.append(el("dt", trait.trait_type), el("dd", trait.value));
      dl.append(row);
    }
    text.append(dl, el("p", "Owner", "fine"));
    const ownerLink = el("a", owner, "back-link") as HTMLAnchorElement;
    ownerLink.href = config.explorer + "/address/" + owner;
    ownerLink.style.overflowWrap = "anywhere";
    text.append(ownerLink, el("p", "Seed / genome", "fine"), el("code", seed));
    box.replaceChildren(img, text);
  } catch (e) {
    box.replaceChildren(el("p", contractError(e, abis).text, "empty"));
  }
}
function route(focus = true) {
  const hash = location.hash.slice(1) || "mine";
  if (hash === "main") {
    $("main").focus();
    return;
  }
  if (hash === "miner") {
    page = "mine";
  } else page = hash.split("/")[0];
  if (
    ![
      "mine",
      "gallery",
      "frog",
      "trade",
      "burn",
      "vault",
      "stake",
      "stats",
    ].includes(page)
  )
    page = "mine";
  document
    .querySelectorAll<HTMLElement>("[data-page]")
    .forEach((n) => (n.hidden = n.dataset.page !== page));
  document.querySelectorAll("nav a").forEach((a) => {
    if (a.getAttribute("href") === "#" + (page === "frog" ? "gallery" : page))
      a.setAttribute("aria-current", "page");
    else a.removeAttribute("aria-current");
  });
  document.title =
    (page === "frog" ? "Frog" : page[0].toUpperCase() + page.slice(1)) +
    " · Hash Frog";
  if (focus) {
    if (hash === "miner") {
      $("miner").scrollIntoView();
      button("start-mining").focus({ preventScroll: true });
    } else {
      const heading = document.querySelector<HTMLElement>(
        '[data-page="' + page + '"] h1',
      );
      if (heading) {
        heading.tabIndex = -1;
        heading.classList.add("route-heading");
        heading.focus({ preventScroll: true });
      }
      window.scrollTo(0, 0);
    }
  }
  if (ready) {
    if (page === "gallery") void loadGallery(true);
    if (page === "frog") void loadDetail(Number(hash.split("/")[1]));
    if (page === "burn") void loadOwned().catch(fail);
    void refresh();
  }
}
window.addEventListener("hashchange", () => route());
button("gallery-prev").onclick = () => {
  galleryPage = Math.max(0, galleryPage - 1);
  void loadGallery(true);
};
button("gallery-next").onclick = () => {
  galleryPage++;
  void loadGallery(true);
};
input("gallery-filter").onchange = () => {
  galleryPage = 0;
  void loadGallery(true);
};
$("find-frog").onsubmit = (e) => {
  e.preventDefault();
  const id = Number(input("find-id").value);
  if (!Number.isInteger(id) || id < 1 || id > 2000) {
    input("find-id").setCustomValidity("Choose an ID from 1 to 2,000.");
    input("find-id").reportValidity();
    return;
  }
  location.hash = "frog/" + id;
};
input("find-id").oninput = () => input("find-id").setCustomValidity("");
input("burn-id").onchange = async () => {
  input("burn-confirm").checked = false;
  buttons();
  $("burn-preview").replaceChildren();
  if (input("burn-id").value)
    try {
      const data = await frogData(Number(input("burn-id").value));
      const img = new Image();
      img.src = data.image;
      img.alt = data.name;
      $("burn-preview").append(img);
    } catch (e) {
      fail(e);
    }
};
input("burn-confirm").onchange = buttons;
async function startJob(text = "Mining your next frog…") {
  if (!mining || !state) return;
  solution = null;
  worker?.terminate();
  worker = null;
  job = null;
  const currentAccount = account;
  const ref = await provider.getBlock(state.head.number - 1);
  if (!mining || account !== currentAccount) return;
  job = {
    id: ++jobNumber,
    account,
    seed: state.seed,
    target: state.target.toString(),
    refBlock: ref.number,
    refHash: ref.hash,
  };
  worker = new Worker(new URL("./miner/worker.js", import.meta.url), {
    type: "module",
  });
  worker.onmessage = ({ data }) => {
    if (data.jobId !== job?.id) return;
    if (data.type === "backend") show("backend", data.backend);
    if (data.type === "progress") {
      show("hashrate", Math.round(data.hashrate).toLocaleString() + " H/s");
      const seconds = Number(1n << 256n) / Number(job!.target) / data.hashrate;
      show(
        "eta",
        seconds < 60
          ? seconds.toFixed(1) + " sec"
          : seconds < 3600
            ? (seconds / 60).toFixed(1) + " min"
            : (seconds / 3600).toFixed(1) + " hr",
      );
    }
    if (data.type === "solution") {
      if (!validProof(job, data.nonce)) {
        stopMining("Proof validation failed. Restart the miner.");
        return;
      }
      solution = { ...job!, nonce: data.nonce };
      mining = false;
      worker?.terminate();
      worker = null;
      show(
        "miner-status",
        "Proof found. Confirm your 0.0019 ETH mint before the seed changes.",
      );
      show("hashrate", "0 H/s · proof found");
      buttons();
    }
    if (data.type === "error") stopMining(data.message);
  };
  worker.onerror = (e) => stopMining("Miner failed: " + e.message);
  worker.postMessage({ action: "start", job });
  show("ref-block", ref.number);
  show("miner-status", text);
  buttons();
}
async function restartMining(text: string, read = true) {
  mining = false;
  worker?.terminate();
  job = null;
  solution = null;
  if (read) await refresh();
  if (!account || !state || state.slots === 0n || state.minted === 2000n) {
    stopMining(text);
    return;
  }
  mining = true;
  await startJob(text);
}
button("start-mining").onclick = async () => {
  if (mining || busy) return;
  try {
    await assertWallet();
    await refresh();
    if (!state?.slots)
      throw new Error("Mint window full. Wait for the next free slot.");
    mining = true;
    buttons();
    await startJob();
  } catch (e) {
    stopMining(contractError(e, abis).text);
    fail(e);
  }
};
button("stop-mining").onclick = () => stopMining();
button("mint").onclick = () =>
  transaction("Mint frog", async () => {
    const proof = solution;
    if (!proof) throw new Error("Start mining to find a valid proof first.");
    const head = await provider.getBlock("latest"),
      opts = { blockTag: head.number };
    const [seed, target, ref, slots] = await Promise.all([
      frog.lastSeed(opts),
      frog["target()"](opts),
      provider.getBlock(proof.refBlock),
      frog.freeSlots(opts),
    ]);
    if (slots[0] === 0n) {
      const e = new Error("Mint window full.");
      (e as any).revert = { name: "HourFull", args: [slots[1]] };
      throw e;
    }
    if (
      staleProof(proof, seed, target, head.number, ref.hash) ||
      account !== proof.account
    ) {
      await restartMining("Puzzle changed. Mining continues on the new seed.");
      throw new Error(
        "The previous proof expired. Mining continues on a fresh puzzle.",
      );
    }
    await frog
      .connect(signer)
      .mine.staticCall(BigInt(proof.nonce), proof.seed, proof.refBlock, {
        value: MINT_VALUE,
      });
    await assertWallet();
    await sent(
      await frog
        .connect(signer)
        .mine(BigInt(proof.nonce), proof.seed, proof.refBlock, {
          value: MINT_VALUE,
        }),
    );
    stopMining("Your frog is minted. Find it in the gallery.");
    galleryKey = "";
  });
function invalidateQuote() {
  quote = null;
  show("trade-quote", "Get a new quote for these settings.");
  show("trade-error", "");
  for (const id of ["trade-amount", "slippage"])
    input(id).removeAttribute("aria-invalid");
  show(
    "amount-label",
    "You pay · " + (input("side").value === "buy" ? "IMD" : "HFROG"),
  );
  buttons();
}
for (const id of ["side", "trade-amount", "slippage"])
  input(id).addEventListener("input", invalidateQuote);
$("trade-form").onsubmit = async (e) => {
  e.preventDefault();
  if (quoteBusy) return;
  quoteBusy = true;
  buttons();
  show("trade-error", "");
  show("trade-quote", "Getting a live quote…");
  try {
    const buy = input("side").value === "buy",
      value = parseAmount(input("trade-amount").value),
      bps = parseSlippage(input("slippage").value);
    const [spent, out] = await router.quote.staticCall(buy, value, 0);
    if (
      buy !== (input("side").value === "buy") ||
      value !== parseAmount(input("trade-amount").value) ||
      bps !== parseSlippage(input("slippage").value)
    )
      return;
    quote = makeQuote(buy, value, spent, out, bps);
    show(
      "trade-quote",
      `You receive ≈ ${fmt(out)} ${buy ? "HFROG" : "IMD"}\nMinimum received: ${formatEther(quote.min)} ${buy ? "HFROG" : "IMD"}\nMaximum spent: ${fmt(spent)} ${buy ? "IMD" : "HFROG"}`,
    );
    const hookFee = buy ? (spent * 150n) / 10000n : (out * 150n) / 9850n,
      lpFee = ((buy ? spent - hookFee : spent) * 12500n) / 1000000n;
    $("fee-breakdown").replaceChildren();
    for (const [label, value] of [
      ["Combined fee before price impact", "2.73125%"],
      ["Hook fee · 1.5% IMD", (buy ? "" : "≈ ") + fmt(hookFee) + " IMD"],
      [
        "LP fee · 1.25% input",
        "≈ " + fmt(lpFee) + " " + (buy ? "IMD" : "HFROG"),
      ],
    ]) {
      const row = el("div");
      row.append(el("dt", label), el("dd", value));
      $("fee-breakdown").append(row);
    }
  } catch (e) {
    quote = null;
    show("trade-quote", "No quote available.");
    show("trade-error", contractError(e, abis).text);
    let bad = "trade-amount";
    try {
      parseAmount(input(bad).value);
      bad = "slippage";
      parseSlippage(input(bad).value);
      bad = "";
    } catch {}
    if (bad) {
      input(bad).setAttribute("aria-invalid", "true");
      input(bad).focus();
    }
  } finally {
    quoteBusy = false;
    buttons();
  }
};
button("swap").onclick = () =>
  transaction("Swap", async () => {
    const q = quote;
    if (
      !q ||
      !quoteValid(
        q,
        input("side").value === "buy",
        parseAmount(input("trade-amount").value),
        parseSlippage(input("slippage").value),
      )
    )
      throw new Error("Get a fresh quote before swapping.");
    await approve(q.buy ? imd : token, config.addresses.FrogRouter, q.input);
    if (
      !quoteValid(
        q,
        input("side").value === "buy",
        parseAmount(input("trade-amount").value),
        parseSlippage(input("slippage").value),
      )
    )
      throw new Error(
        "Quote expired or settings changed during approval. Get a fresh quote.",
      );
    await assertWallet();
    await sent(
      await router
        .connect(signer)
        .swap(q.buy, q.input, q.min, 0, await deadline()),
    );
    invalidateQuote();
  });
button("burn-button").onclick = () =>
  transaction("Burn frog", async () => {
    const id = Number(input("burn-id").value);
    if (!input("burn-confirm").checked || !id)
      throw new Error("Choose your frog and acknowledge the permanent burn.");
    if ((await frog.ownerOf(id)).toLowerCase() !== account.toLowerCase())
      throw new Error(
        "This wallet no longer owns that frog. Refresh your collection.",
      );
    await sent(await frog.connect(signer).burn(id));
    cachedFrogs.delete(id);
    input("burn-confirm").checked = false;
    $("burn-preview").replaceChildren();
    ownedKey = "";
    galleryKey = "";
  });
button("buyback").onclick = () =>
  transaction("Vault buyback", async () => {
    const value = parseAmount(input("buyback-amount").value);
    if (value > 100n * 10n ** 18n || value > state!.vaultIMD)
      throw new Error(
        "Enter an amount within the vault balance and the 100 IMD limit.",
      );
    await hook.consult();
    const [, out] = await router.quote.staticCall(true, value, 0);
    await sent(
      await frog
        .connect(signer)
        .buyback(value, (out * 9950n) / 10000n, 0, await deadline()),
    );
  });
button("stake-button").onclick = () =>
  transaction("Stake HFROG", async () => {
    const value = parseAmount(input("stake-amount").value);
    if (value > state!.balance!)
      throw new Error("Enter an amount within your HFROG balance.");
    await approve(token, config.addresses.FrogStaking, value);
    await sent(await staking.connect(signer).stake(value));
  });
button("request-exit").onclick = () =>
  transaction("Request unstake", async () => {
    const value = parseAmount(input("stake-amount").value);
    if (value > state!.position.active)
      throw new Error("Enter an amount within your active stake.");
    await sent(await staking.connect(signer).requestUnstake(value));
  });
button("claim").onclick = () =>
  transaction("Claim IMD", async () =>
    sent(await staking.connect(signer).claim()),
  );
button("withdraw-stake").onclick = () =>
  transaction("Withdraw HFROG", async () =>
    sent(await staking.connect(signer).unstake()),
  );
button("flush").onclick = () =>
  transaction("Forward pending ETH", async () =>
    sent(await frog.connect(signer).flush()),
  );
button("redeem").onclick = () =>
  transaction("Redeem team fees", async () =>
    sent(await hook.connect(signer).redeemFees()),
  );
button("refresh").onclick = async () => {
  galleryKey = "";
  ownedKey = "";
  if (!ready) await initialize().catch(fail);
  else await refresh();
  if (page === "frog") await loadDetail(Number(location.hash.split("/")[1]));
};
window.addEventListener("pagehide", () => stopMining());
route(false);
buttons();
initialize()
  .then(() => route(false))
  .catch((e) => {
    show("launch-status", "Unable to connect");
    fail(e);
    buttons();
  });
setInterval(() => {
  void refresh();
}, 12000);
setInterval(tick, 1000);
