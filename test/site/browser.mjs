// Real exported site + deployed contracts on an isolated mainnet fork. No deployments.
// Anvil is local only; its test accounts have no mainnet signing role.
import { randomBytes } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import http from "node:http";
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import {
  JsonRpcProvider,
  Contract,
  AbiCoder,
  keccak256,
  toBeHex,
  Interface,
  getAddress,
} from "../../site/vendor/ethers.js";
const root = fileURLToPath(new URL("../../", import.meta.url));
process.chdir(root);
const require = createRequire(
  new URL("../../web/package.json", import.meta.url),
);
const { chromium } = require("playwright");
const { default: AxeBuilder } = await import(
  path.join(root, "web/node_modules/@axe-core/playwright/dist/index.mjs")
);
const config = JSON.parse(fs.readFileSync("dist/config.json")),
  abi = JSON.parse(fs.readFileSync("dist/abi.json")),
  verification = JSON.parse(fs.readFileSync("docs/mainnet-verification.json"));
const scratch = path.join(root, "test/scratch");
fs.mkdirSync(scratch, { recursive: true });
const report = {
  date: new Date().toISOString(),
  checks: [],
  widths: [],
  axe: [],
  consoleErrors: [],
  resourceFailures: [],
  limitations: [
    "WalletConnect pairing requires a project ID and an external wallet; not exercised.",
    "No physical GPU or hardware wallet tested. Browser miner exercised WASM fallback.",
    "All write interactions use a local mainnet fork, with a funded IMD test account. No live transactions or contract deployments.",
  ],
};
const mime = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".css": "text/css",
  ".svg": "image/svg+xml",
  ".json": "application/json",
  ".wasm": "application/wasm",
  ".wgsl": "text/plain",
  ".txt": "text/plain",
};
const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://localhost");
  let name = decodeURIComponent(url.pathname.replace(/^\/pond\//, "/"));
  if (name === "/") name = "/index.html";
  const target = path.resolve(root, "dist", "." + name);
  if (
    !target.startsWith(path.join(root, "dist") + path.sep) ||
    !fs.existsSync(target) ||
    fs.statSync(target).isDirectory()
  ) {
    res.writeHead(404);
    res.end();
    return;
  }
  res.setHeader(
    "Content-Type",
    mime[path.extname(target)] || "application/octet-stream",
  );
  fs.createReadStream(target).pipe(res);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = "http://127.0.0.1:" + server.address().port + "/pond/";
let browser, p, anvil, activePage;
const log = (s) => {
  report.checks.push(s);
  console.log("PASS " + s);
};
try {
  browser = await chromium.launch({
    headless: true,
    executablePath: process.env.HASHFROG_CHROME || "/opt/google/chrome/chrome",
    args: ["--no-sandbox", "--disable-gpu"],
  });
  const liveContext = await browser.newContext({
    viewport: { width: 1440, height: 1000 },
    reducedMotion: "reduce",
  });
  const page = await liveContext.newPage();
  page.on("pageerror", (e) => report.consoleErrors.push(e.message));
  page.on("requestfailed", (r) => {
    if (r.url().startsWith(base))
      report.resourceFailures.push({
        url: r.url(),
        error: r.failure()?.errorText,
      });
  });
  await page.goto(base);
  await page.waitForFunction(
    () =>
      document.querySelector("#launch-status").textContent.startsWith("Live"),
    {},
    { timeout: 60000 },
  );
  for (const width of [1440, 768, 390, 320]) {
    await page.setViewportSize({ width, height: 900 });
    for (const route of [
      "mine",
      "gallery",
      "trade",
      "burn",
      "vault",
      "stake",
      "stats",
    ]) {
      await page.locator('nav a[href="#' + route + '"]').click();
      await page.waitForTimeout(100);
      const dimensions = await page.evaluate(() => ({
        width: innerWidth,
        scroll: document.documentElement.scrollWidth,
      }));
      assert(
        dimensions.scroll <= dimensions.width,
        route + " overflow at " + width,
      );
      assert.equal(await page.locator("main h1:visible").count(), 1);
    }
    report.widths.push(width);
  }
  log(
    "All seven hash views reflow at 1440, 768, 390 and 320 px, with one visible h1 and no page overflow.",
  );
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.locator('nav a[href="#trade"]').click();
  await page.locator("#trade-amount").fill("-1");
  await page.locator("#quote-trade").click();
  assert.match(
    await page.locator("#trade-error").textContent(),
    /positive amount/,
  );
  assert.equal(
    await page.locator("#trade-amount").getAttribute("aria-invalid"),
    "true",
  );
  await page.locator("#trade-amount").fill("1");
  await page.locator("#quote-trade").click();
  await page.waitForFunction(
    () =>
      document
        .querySelector("#trade-quote")
        .textContent.includes("Minimum received"),
    {},
    { timeout: 30000 },
  );
  assert.match(await page.locator("#trade-quote").textContent(), /HFROG/);
  assert(await page.locator("#swap").isDisabled());
  log(
    "Disconnected live quote, exact minimum display and invalid-amount inline error.",
  );
  for (const route of [
    "mine",
    "gallery",
    "trade",
    "burn",
    "vault",
    "stake",
    "stats",
  ]) {
    await page.locator('nav a[href="#' + route + '"]').click();
    const results = await new AxeBuilder({ page })
      .withTags(["wcag2a", "wcag2aa", "wcag21aa"])
      .analyze();
    report.axe.push({
      route,
      violations: results.violations.map((x) => ({
        id: x.id,
        impact: x.impact,
        nodes: x.nodes.map((n) => n.target),
      })),
    });
  }
  await page.locator("#connect").click();
  assert(await page.locator("#wallet-dialog").isVisible());
  await page.keyboard.press("Escape");
  assert(await page.locator("#wallet-dialog").isHidden());
  assert.equal(await page.evaluate(() => document.activeElement.id), "connect");
  log("Native wallet dialog Escape dismissal and focus restoration.");
  await page.locator('nav a[href="#mine"]').click();
  await page.evaluate(() => (document.documentElement.style.zoom = "2"));
  assert(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  );
  await page.evaluate(() => (document.documentElement.style.zoom = ""));
  await page.evaluate(() => (document.documentElement.dir = "rtl"));
  assert(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  );
  await page.evaluate(() => (document.documentElement.dir = "ltr"));
  log("Mine page at CSS 200% zoom and RTL mirror has no page overflow.");
  // Fork the pinned existing deployment. No constructor or deployment is called.
  anvil = spawn(
    "anvil",
    [
      "--fork-url",
      config.rpcUrls[0],
      "--fork-block-number",
      String(verification.blockNumber),
      "--port",
      "18546",
      "--host",
      "127.0.0.1",
      "--chain-id",
      "1",
      "--block-time",
      "1",
      "--silent",
      "--no-storage-caching",
    ],
    { stdio: ["ignore", "ignore", "pipe"] },
  );
  const fork = "http://127.0.0.1:18546";
  p = new JsonRpcProvider(fork, 1, { staticNetwork: true, cacheTimeout: -1 });
  for (let i = 0; i < 100; i++) {
    try {
      await p.send("eth_chainId", []);
      break;
    } catch {
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  const account = getAddress("0x" + randomBytes(20).toString("hex"));
  assert.equal(await p.getCode(account), "0x");
  await p.send("anvil_impersonateAccount", [account]);
  await p.send("anvil_setBalance", [account, toBeHex(100n * 10n ** 18n)]);
  const imd = new Contract(config.addresses.IMD, abi.HFROG, p),
    frog = new Contract(config.addresses.HashFrog, abi.HashFrog, p),
    staking = new Contract(config.addresses.FrogStaking, abi.FrogStaking, p);
  // Locate the deployed IMD balance mapping by reversible local-fork probes.
  let funded = false;
  for (let slot = 0; slot < 30; slot++) {
    const key = keccak256(
        AbiCoder.defaultAbiCoder().encode(
          ["address", "uint256"],
          [account, slot],
        ),
      ),
      old = await p.getStorage(config.addresses.IMD, key);
    await p.send("anvil_setStorageAt", [
      config.addresses.IMD,
      key,
      toBeHex(1000n * 10n ** 18n, 32),
    ]);
    if ((await imd.balanceOf(account)) === 1000n * 10n ** 18n) {
      funded = true;
      break;
    }
    await p.send("anvil_setStorageAt", [config.addresses.IMD, key, old]);
  }
  assert(funded);
  const context = await browser.newContext({
    viewport: { width: 1440, height: 1000 },
    reducedMotion: "reduce",
  });
  await context.route("**/config.json", (r) =>
    r.fulfill({ json: { ...config, rpcUrls: [fork] } }),
  );
  await context.addInitScript(
    ({ rpc, account }) => {
      const listeners = {};
      window.testChain = "0x2";
      window.sentTransactions = [];
      window.rpcTrace = [];
      window.walletEvents = listeners;
      window.ethereum = {
        on: (name, cb) => (listeners[name] ??= []).push(cb),
        removeListener: (name, cb) =>
          (listeners[name] = (listeners[name] || []).filter((x) => x !== cb)),
        request: async ({ method, params = [] }) => {
          if (method === "eth_chainId") return window.testChain;
          if (method === "eth_accounts" || method === "eth_requestAccounts")
            return [account];
          if (method === "wallet_switchEthereumChain") {
            window.testChain = "0x1";
            for (const cb of listeners.chainChanged || []) cb("0x1");
            return null;
          }
          if (method === "eth_sendTransaction")
            window.sentTransactions.push(params[0]);
          const res = await fetch(rpc, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
          });
          const data = await res.json();
          if (
            [
              "eth_sendTransaction",
              "eth_getTransactionReceipt",
              "eth_blockNumber",
            ].includes(method)
          ) {
            window.rpcTrace.push({
              method,
              result: data.result,
              error: data.error,
            });
            window.rpcTrace = window.rpcTrace.slice(-25);
          }
          if (data.error) throw data.error;
          return data.result;
        },
      };
    },
    { rpc: fork, account },
  );
  const app = await context.newPage();
  activePage = app;
  app.setDefaultTimeout(45000);
  app.on("pageerror", (e) => report.consoleErrors.push(e.message));
  await app.goto(base);
  await app.waitForFunction(() =>
    document.querySelector("#launch-status").textContent.startsWith("Live"),
  );
  await app.locator("#connect").click();
  await app
    .getByRole("button", { name: "Connect Browser wallet", exact: true })
    .click();
  await app.waitForFunction(() =>
    document
      .querySelector("#wallet-status")
      .textContent.includes("Wrong network"),
  );
  assert(await app.locator("#start-mining").isDisabled());
  await app.locator("#switch-network").click();
  await app.waitForFunction(
    () => !document.querySelector("#wallet-dialog").open,
  );
  await app.waitForFunction(
    () => !document.querySelector("#start-mining").disabled,
  );
  log("Injected wallet connection, wrong-network gate and switch to Ethereum.");
  await app.locator("#start-mining").click();
  await app.waitForFunction(
    () =>
      document
        .querySelector("#miner-status")
        .textContent.includes("Proof found"),
    {},
    { timeout: 120000 },
  );
  report.minerBackend = await app.locator("#backend").textContent();
  await app.locator("#mint").click();
  await app.waitForFunction(
    () =>
      document
        .querySelector("#notice")
        .textContent.includes("Mint frog confirmed"),
    {},
    { timeout: 60000 },
  );
  assert.equal(await frog.ownerOf(1), account);
  log(
    "Production browser worker finds a proof and mints against deployed NFT code on the fork.",
  );
  await app.locator('nav a[href="#gallery"]').click();
  await app.locator(".frog-card").first().click();
  await app.waitForFunction(() => document.querySelector("#detail-content h1"));
  assert.match(await app.locator("#detail-content").textContent(), /Skin/);
  log("tokenURI gallery card opens frog detail with traits and owner.");
  async function route(name) {
    await app.locator('nav a[href="#' + name + '"]').click();
    await app.waitForFunction(
      () => !document.querySelector("#refresh").disabled,
    );
  }
  async function confirmed(label) {
    await app.waitForFunction(
      (text) => document.querySelector("#notice").textContent.includes(text),
      label + " confirmed.",
      { timeout: 60000 },
    );
    await app.waitForFunction(
      () => !document.querySelector("#refresh").disabled,
    );
  }
  await route("trade");
  await app.locator("#trade-amount").fill("1");
  await app.locator("#quote-trade").click();
  await app.waitForFunction(() => !document.querySelector("#swap").disabled);
  await app.locator("#swap").click();
  await confirmed("Swap");
  log(
    "Buy HFROG with exact allowance and quote-bound minimum through FrogRouter.",
  );
  await route("stake");
  await app.locator("#stake-amount").fill("10");
  await app.locator("#stake-button").click();
  await confirmed("Stake HFROG");
  assert.equal((await staking.positions(account)).active, 10n ** 19n);
  log("Stake HFROG with an exact approval.");
  await route("trade");
  await app.locator("#side").selectOption("sell");
  await app.locator("#trade-amount").fill("1000");
  await app.locator("#quote-trade").click();
  await app.waitForFunction(() => !document.querySelector("#swap").disabled);
  await app.locator("#swap").click();
  await confirmed("Swap");
  log("Sell HFROG for IMD through FrogRouter.");
  await route("stake");
  await app.waitForFunction(() => !document.querySelector("#claim").disabled);
  await app.locator("#claim").click();
  await confirmed("Claim IMD");
  assert((await staking.totalClaimed()) > 0n);
  await app.locator("#request-exit").click();
  await confirmed("Request unstake");
  assert(await app.locator("#withdraw-stake").isDisabled());
  assert.match(await app.locator("#exit-time").textContent(), /[hm]/);
  log("Claim IMD and start the 24-hour delay; early withdrawal is disabled.");
  await p.send("evm_increaseTime", [86401]);
  await p.send("evm_mine", []);
  await app.locator("#refresh").click();
  await app.waitForFunction(
    () => !document.querySelector("#withdraw-stake").disabled,
  );
  await app.locator("#withdraw-stake").click();
  await confirmed("Withdraw HFROG");
  assert.equal((await staking.positions(account)).exiting, 0n);
  log("Withdraw matured HFROG after the simulated 24-hour countdown.");
  await route("vault");
  await app.locator("#buyback-amount").fill("0.001");
  await app.locator("#buyback").click();
  await confirmed("Vault buyback");
  assert((await frog.totalBoughtHFROG()) > 0n);
  assert.match(
    await app.locator("#buyback-status").textContent(),
    /Next buyback/,
  );
  assert(await app.locator("#buyback").isDisabled());
  log("Permissionless vault buyback and live 60-second cooldown gate.");
  await route("burn");
  await app.locator("#burn-id").selectOption("1");
  assert(await app.locator("#burn-button").isDisabled());
  await app.locator("#burn-confirm").check();
  await app.locator("#burn-button").click();
  await confirmed("Burn frog");
  assert.equal(await frog.totalBurned(), 1n);
  log(
    "Owned frog selector, vault-share preview, explicit burn acknowledgement and permanent burn.",
  );
  await route("stats");
  assert.match(await app.locator("#stats-minted").textContent(), /1 \/ 2,000/);
  assert(
    Number((await app.locator("#hack-eth").textContent()).split(" ")[0]) > 0,
  );
  log(
    "Mint, ETH payout, rewards and price statistics refresh after transactions.",
  );
  const txs = await app.evaluate(() => window.sentTransactions);
  const nft = new Interface(abi.HashFrog);
  const mint = txs.find(
    (t) =>
      t.to.toLowerCase() === config.addresses.HashFrog.toLowerCase() &&
      t.data.startsWith(nft.getFunction("mine").selector),
  );
  assert(mint);
  assert.equal(BigInt(mint.value), 1900000000000000n);
  report.transactionCount = txs.length;
  await app.evaluate(() => {
    window.testChain = "0x2";
    for (const cb of window.walletEvents.chainChanged || []) cb("0x2");
  });
  assert(await app.locator("#claim").isDisabled());
  assert.match(await app.locator("#notice").textContent(), /Ethereum mainnet/);
  log(
    "Wallet chain changes clear account state and disable fund-moving controls.",
  );
  assert.deepEqual(report.consoleErrors, []);
  assert.deepEqual(report.resourceFailures, []);
  assert(
    report.axe.every((x) => x.violations.length === 0),
    JSON.stringify(report.axe),
  );
  log(
    "No uncaught browser errors, static resource failures, or axe WCAG A/AA violations in the seven main views.",
  );
  fs.writeFileSync(
    "docs/browser-validation.json",
    JSON.stringify(report, null, 2) + "\n",
  );
  console.log("All browser/fork checks passed.");
} catch (error) {
  if (activePage)
    report.failureUI = await activePage.evaluate(() => ({
      notice: document.querySelector("#notice")?.textContent,
      miner: document.querySelector("#miner-status")?.textContent,
      transactions: window.sentTransactions,
      rpcTrace: window.rpcTrace,
    }));
  fs.writeFileSync(
    "test/scratch/browser-failure.json",
    JSON.stringify({ ...report, error: error.stack }, null, 2),
  );
  throw error;
} finally {
  await browser?.close();
  p?.destroy();
  anvil?.kill("SIGTERM");
  await new Promise((r) => server.close(r));
}
