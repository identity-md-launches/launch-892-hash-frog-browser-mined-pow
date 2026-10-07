// Read-only launch verification. No private key, signing, transaction or deployment.
import fs from "node:fs";
import {
  JsonRpcProvider,
  Contract,
  keccak256,
  toUtf8Bytes,
  toBeHex,
  AbiCoder,
  solidityPackedKeccak256,
} from "../site/vendor/ethers.js";
process.chdir(new URL("../", import.meta.url).pathname);
const read = (p) => JSON.parse(fs.readFileSync(p, "utf8"));
const pinned = fs.existsSync(".imd/reads/deployment.json");
const deployment = read(
  pinned ? ".imd/reads/deployment.json" : "docs/launch-deployment.json",
);
const network = read(
  pinned ? ".imd/reads/network.json" : "docs/launch-network.json",
);
const abis = read("site/abi.json");
const canonical = (x) =>
  Array.isArray(x)
    ? x.map(canonical)
    : x && typeof x === "object"
      ? Object.fromEntries(
          Object.keys(x)
            .sort()
            .map((k) => [k, canonical(x[k])]),
        )
      : x;
const report = {
  checkedAt: new Date().toISOString(),
  chainId: 1,
  sourceCommit: deployment.sourceCommit,
  abiHashes: {},
  checks: {},
  limitations: [],
};
for (const c of deployment.contracts) {
  const hash = keccak256(
    toUtf8Bytes(JSON.stringify(canonical(abis[c.name]))),
  ).slice(2);
  if (hash !== c.abiHash) throw new Error("ABI mismatch: " + c.name);
  report.abiHashes[c.name] = hash;
  const path = `test/scratch/out/${c.name}.sol/${c.name}.json`;
  if (
    fs.existsSync(path) &&
    JSON.stringify(canonical(read(path).abi)) !==
      JSON.stringify(canonical(abis[c.name]))
  )
    throw new Error("Compiled ABI mismatch: " + c.name);
}
for (const name of Object.keys(abis)) {
  const path = `test/scratch/out/${name}.sol/${name}.json`;
  if (
    fs.existsSync(path) &&
    JSON.stringify(canonical(read(path).abi)) !==
      JSON.stringify(canonical(abis[name]))
  )
    throw new Error("Compiled companion ABI mismatch: " + name);
}
const p = new JsonRpcProvider(network.network.rpcUrls[0], 1, {
  staticNetwork: true,
  cacheTimeout: -1,
});
try {
  if (BigInt(await p.send("eth_chainId", [])) !== 1n)
    throw new Error("Wrong chain");
  const head = await p.getBlock("latest"),
    tag = head.number,
    opts = { blockTag: tag };
  report.blockNumber = tag;
  report.blockHash = head.hash;
  const hookAddress = deployment.contracts.find(
    (c) => c.name === "HashFrogHook",
  ).address;
  const hook = new Contract(hookAddress, abis.HashFrogHook, p);
  const addresses = {
    HashFrogHook: hookAddress,
    HFROG: await hook.hfrog(opts),
    HashFrog: await hook.frog(opts),
    FrogStaking: await hook.staking(opts),
    FrogRouter: await hook.router(opts),
    IMD: await hook.imd(opts),
    PoolManager: await hook.poolManager(opts),
  };
  if (
    addresses.HFROG.toLowerCase() !==
    deployment.contracts.find((c) => c.name === "HFROG").address.toLowerCase()
  )
    throw new Error("Token mismatch");
  if (
    addresses.IMD.toLowerCase() !==
    network.network.pairToken.address.toLowerCase()
  )
    throw new Error("IMD mismatch");
  const codeHashes = {};
  for (const [n, a] of Object.entries(addresses)) {
    const code = await p.getCode(a, tag);
    if (code === "0x") throw new Error("No code: " + n);
    codeHashes[n] = keccak256(code);
    const artifactPath = `test/scratch/out/${n}.sol/${n}.json`;
    if (abis[n] && fs.existsSync(artifactPath)) {
      const bytecode = read(artifactPath).deployedBytecode;
      const actual = Buffer.from(code.slice(2), "hex"),
        built = Buffer.from(bytecode.object.replace(/^0x/, ""), "hex");
      for (const refs of Object.values(bytecode.immutableReferences || {}))
        for (const { start, length } of refs) {
          actual.fill(0, start, start + length);
          built.fill(0, start, start + length);
        }
      if (!actual.equals(built))
        throw new Error("Runtime source mismatch: " + n);
      (report.runtimeSourceMatches ??= {})[n] =
        "Compiled runtime matches after masking compiler-listed immutable locations";
    }
  }
  const frog = new Contract(addresses.HashFrog, abis.HashFrog, p),
    router = new Contract(addresses.FrogRouter, abis.FrogRouter, p);
  addresses.Hackathon = await frog.HACKATHON(opts);
  addresses.Team = await frog.TEAM(opts);
  const target = await frog["target()"](opts),
    seed = await frog.lastSeed(opts),
    slots = await frog.freeSlots(opts),
    minted = await frog.totalMinted(opts);
  report.addresses = addresses;
  report.codeHashes = codeHashes;
  report.checks = {
    target: String(target),
    lastSeed: seed,
    freeSlots: String(slots[0]),
    nextSlotAt: String(slots[1]),
    totalMinted: String(minted),
  };
  const [spent, received] = await router.quote.staticCall(
    true,
    10n ** 18n,
    0,
    opts,
  );
  if (received <= 0n) throw new Error("No buy liquidity");
  report.checks.buyQuote = {
    inputIMD: String(spent),
    outputHFROG: String(received),
  };
  const ref = await p.getBlock(tag - 1),
    from = addresses.Hackathon;
  let nonce = 0n;
  while (
    BigInt(
      solidityPackedKeccak256(
        ["address", "uint256", "bytes32", "bytes32"],
        [from, nonce, seed, ref.hash],
      ),
    ) < target
  )
    nonce++;
  try {
    await frog.mine.staticCall(nonce, seed, ref.number, {
      ...opts,
      from,
      value: 1900000000000000n,
    });
    throw new Error("Fake proof unexpectedly accepted");
  } catch (e) {
    const data = e.data || e.info?.error?.data;
    let decoded;
    try {
      decoded = frog.interface.parseError(data);
    } catch {}
    if (!decoded) throw e;
    report.checks.fakeMint = {
      nonce: String(nonce),
      valueWei: "1900000000000000",
      refBlock: ref.number,
      revert: decoded.name,
      revertData: data,
    };
  }
  let uri;
  if (minted > 0n) {
    for (let id = Number(minted); id > 0; id--) {
      try {
        uri = await frog.tokenURI(id, opts);
        report.checks.tokenURI = { mode: "live minted token", id };
        break;
      } catch {}
    }
  }
  if (!uri) {
    try {
      await frog.tokenURI(1, opts);
    } catch (e) {
      report.checks.unmintedTokenURIRevert = e.revert?.name || e.shortMessage;
    }
    report.limitations.push(
      "No live minted token was available. Sample tokenURI uses eth_call state overrides on the deployed NFT; no state persisted and no NFT was minted.",
    );
    const layout = read("test/scratch/storage.json").storage;
    const slot = (name) => BigInt(layout.find((x) => x.label === name).slot);
    const coder = AbiCoder.defaultAbiCoder(),
      key = (s) => keccak256(coder.encode(["uint256", "uint256"], [1n, s]));
    const diff = {
      [key(slot("_owners"))]: toBeHex(BigInt(from), 32),
      [key(slot("seedOf"))]: seed,
    };
    try {
      const result = await p.send("eth_call", [
        {
          to: addresses.HashFrog,
          gas: "0x989680",
          data: frog.interface.encodeFunctionData("tokenURI", [1]),
        },
        "0x" + tag.toString(16),
        { [addresses.HashFrog]: { stateDiff: diff } },
      ]);
      [uri] = frog.interface.decodeFunctionResult("tokenURI", result);
      report.checks.tokenURI = {
        mode: "mainnet eth_call, sample genesis seed with temporary state override",
        id: 1,
        seed,
      };
    } catch (e) {
      report.limitations.push(
        "RPC sample state override unavailable: " +
          (e.shortMessage || e.message),
      );
    }
  }
  if (uri) {
    const meta = JSON.parse(Buffer.from(uri.split(",")[1], "base64"));
    report.checks.tokenURI.name = meta.name;
    report.checks.tokenURI.attributes = meta.attributes;
    report.checks.tokenURI.keccak = keccak256(toUtf8Bytes(uri));
    fs.writeFileSync(
      "site/sample-frog.svg",
      Buffer.from(meta.image.split(",")[1], "base64"),
    );
    fs.writeFileSync(
      "docs/sample-tokenURI.json",
      JSON.stringify(meta, null, 2) + "\n",
    );
  }
  const config = {
    chainId: 1,
    launch: 892,
    hook: hookAddress,
    addresses,
    codeHashes,
    rpcUrls: network.network.rpcUrls,
    explorer: network.network.explorer,
    repoUrl: deployment.repoUrl,
    sourceCommit: deployment.sourceCommit,
    deploymentBlock: deployment.contracts[0].blockNumber,
    walletConnectProjectId: fs.existsSync("site/config.json")
      ? read("site/config.json").walletConnectProjectId || ""
      : "",
    walletAddChain: network.walletAddChain,
  };
  fs.writeFileSync("site/config.json", JSON.stringify(config, null, 2) + "\n");
  if (pinned) {
    fs.copyFileSync(
      ".imd/reads/deployment.json",
      "docs/launch-deployment.json",
    );
    fs.copyFileSync(".imd/reads/network.json", "docs/launch-network.json");
  }
  fs.writeFileSync(
    "docs/mainnet-verification.json",
    JSON.stringify(report, null, 2) + "\n",
  );
  console.log(JSON.stringify(report, null, 2));
} finally {
  p.destroy();
}
