import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { Interface } from "../../site/vendor/ethers.js";
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
} from "../../site/logic.ts";
const abis = JSON.parse(
  fs.readFileSync(new URL("../../site/abi.json", import.meta.url)),
);
test("amounts remain exact and malformed/negative/zero amounts cannot be spent", () => {
  assert.equal(parseAmount("0.0019"), MINT_VALUE);
  assert.equal(
    parseAmount("9007199254740993.000000000000000001"),
    9007199254740993000000000000000001n,
  );
  for (const amount of ["-1", "0", "1e3", "1.0000000000000000001", "NaN", ""])
    assert.throws(() => parseAmount(amount));
  for (const value of ["0", "5.01", "Infinity", "1e0", "-1"])
    assert.throws(() => parseSlippage(value));
  assert.equal(parseSlippage("0.5"), 50n);
});
test("minimum output is bound to direction, input, slippage and quote age", () => {
  const q = makeQuote(true, 1000n, 1000n, 9999n, 50n, 1000);
  assert.equal(q.min, 9949n);
  assert(quoteValid(q, true, 1000n, 50n, 60999));
  assert(!quoteValid(q, true, 1000n, 50n, 61000));
  assert(!quoteValid(q, false, 1000n, 50n, 1000));
  assert(!quoteValid(q, true, 1001n, 50n, 1000));
  assert(!quoteValid(q, true, 1000n, 100n, 1000));
  assert.throws(() => makeQuote(true, 1n, 1n, 1n, 50n));
});
test("stale seed, target, old reference, reorg and future block invalidate work", () => {
  const job = {
    id: 1,
    account: "a",
    seed: "seed",
    target: "12",
    refBlock: 100,
    refHash: "hash",
  };
  assert(!staleProof(job, "seed", 12n, 120, "hash"));
  assert(staleProof(job, "new", 12n, 120));
  assert(staleProof(job, "seed", 13n, 120));
  assert(staleProof(job, "seed", 12n, 149));
  assert(staleProof(job, "seed", 12n, 120, "reorg"));
  assert(staleProof(job, "seed", 12n, 100));
});
test("the exact live fake-mint error and wrapped wallet errors are recoverable", () => {
  const live = JSON.parse(
    fs.readFileSync(
      new URL("../../docs/mainnet-verification.json", import.meta.url),
    ),
  );
  assert.equal(live.checks.fakeMint.valueWei, String(MINT_VALUE));
  assert.match(
    contractError(
      { info: { error: { data: live.checks.fakeMint.revertData } } },
      abis,
    ).text,
    /Invalid proof/,
  );
  const iface = new Interface(abis.HashFrog);
  assert.match(
    contractError(
      { data: iface.encodeErrorResult("HourFull", [1800000000]) },
      abis,
    ).text,
    /Mint window full/,
  );
  for (const name of ["StaleSeed", "InvalidReferenceBlock"])
    assert.match(
      contractError({ data: iface.encodeErrorResult(name, []) }, abis).text,
      /Mining continues/,
    );
  assert.match(contractError({ code: 4001 }, abis).text, /declined/);
});
test("countdown and metadata respect their contract representations", () => {
  assert.equal(countdown(86400, 0), "24h 0m 0s");
  assert.equal(countdown(86400, 86400), "Ready now");
  const data = JSON.parse(
    fs.readFileSync(
      new URL("../../docs/sample-tokenURI.json", import.meta.url),
    ),
  );
  assert.equal(
    decodeMetadata(
      "data:application/json;base64," +
        Buffer.from(JSON.stringify(data)).toString("base64"),
    ).name,
    "Hash Frog #1",
  );
  assert.throws(() => decodeMetadata("https://malicious.invalid/metadata"));
});
