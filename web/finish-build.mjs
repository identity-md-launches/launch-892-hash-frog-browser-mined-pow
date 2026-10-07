import {
  copyFile,
  mkdir,
  writeFile,
  readdir,
  stat,
  readFile,
} from "node:fs/promises";
for (const file of ["config.json", "abi.json", "vendor/ethers.LICENSE.md"]) {
  const dest = new URL("../dist/" + file, import.meta.url);
  await mkdir(new URL(".", dest), { recursive: true });
  await copyFile(new URL("../site/" + file, import.meta.url), dest);
}
// Dependency notices stay alongside the static runtime.
await copyFile(
  new URL("../docs/frontend-NOTICE.txt", import.meta.url),
  new URL("../dist/NOTICE.txt", import.meta.url),
);
async function walk(url) {
  let bytes = 0;
  for (const n of await readdir(url)) {
    const p = new URL(n, url);
    const s = await stat(p);
    bytes += s.isDirectory() ? await walk(new URL(n + "/", url)) : s.size;
  }
  return bytes;
}
const lock = JSON.parse(
  await readFile(new URL("./package-lock.json", import.meta.url), "utf8"),
);
const notices = [];
for (const [name, pkg] of Object.entries(lock.packages)) {
  if (!name || pkg.dev || !name.startsWith("node_modules/")) continue;
  const dir = new URL("./" + name + "/", import.meta.url);
  try {
    for (const file of await readdir(dir))
      if (/^licen[cs]e(?:\.|$)/i.test(file)) {
        const body = await readFile(new URL(file, dir), "utf8");
        notices.push(name + " @ " + pkg.version + "\n" + body);
      }
  } catch {}
}
await writeFile(
  new URL("../dist/THIRD-PARTY-LICENSES.txt", import.meta.url),
  notices.join("\n\n--------------------\n\n"),
);
const bytes = await walk(new URL("../dist/", import.meta.url));
if (bytes > 4 * 1024 * 1024)
  throw new Error("Static export exceeds its 4 MiB budget: " + bytes);
console.log("Complete static export: " + bytes + " bytes.");
