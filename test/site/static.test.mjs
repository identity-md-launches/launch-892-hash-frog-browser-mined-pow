import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
const dist = new URL("../../dist/", import.meta.url);
test("production export has relative complete local entry assets and live deployment configuration", () => {
  const html = fs.readFileSync(new URL("index.html", dist), "utf8");
  for (const [, url] of html.matchAll(/(?:src|href)="([^"]+)"/g)) {
    if (url.startsWith("#") || url.startsWith("https:")) continue;
    assert(url.startsWith("./"), "relative URL: " + url);
    assert(fs.existsSync(new URL(url, dist)), "missing asset " + url);
  }
  const config = JSON.parse(fs.readFileSync(new URL("config.json", dist)));
  assert.equal(config.chainId, 1);
  assert.equal(config.launch, 892);
  assert(config.addresses.FrogRouter);
  assert.equal(Object.keys(config.codeHashes).length, 7);
});
test("static export has no dependency caches, source maps or package archives", () => {
  function walk(dir) {
    for (const name of fs.readdirSync(dir)) {
      assert(!/^(node_modules|\.cache|\.vite)$/.test(name));
      assert(!/\.(tgz|map)$/.test(name));
      const child = path.join(dir, name);
      if (fs.statSync(child).isDirectory()) walk(child);
    }
  }
  walk(dist.pathname);
});
