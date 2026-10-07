import { defineConfig } from "vite";
import { fileURLToPath } from "node:url";
const local = (path: string) => fileURLToPath(new URL(path, import.meta.url));
export default defineConfig({
  root: local("../site"),
  base: "./",
  publicDir: false,
  resolve: {
    alias: {
      "@walletconnect/ethereum-provider": local(
        "./node_modules/@walletconnect/ethereum-provider/dist/index.js",
      ),
      qrcode: local("./node_modules/qrcode/lib/browser.js"),
    },
  },
  build: {
    outDir: local("../dist"),
    emptyOutDir: true,
    target: "es2022",
    assetsInlineLimit: 0,
  },
  worker: { format: "es" },
});
